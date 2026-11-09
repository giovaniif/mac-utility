//! Pure rectangle math in screen pixels: origin at the top-left of the
//! primary display, y growing down (the Win32 and X11 convention).

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.w / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.0
    }
    pub fn inset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, (self.w - 2.0 * dx).max(0.0), (self.h - 2.0 * dy).max(0.0))
    }
    /// Smallest whole-pixel rect containing this one, like CGRect.integral.
    pub fn integral(&self) -> Rect {
        let (x, y) = (self.x.floor(), self.y.floor());
        Rect::new(x, y, self.max_x().ceil() - x, self.max_y().ceil() - y)
    }
    pub fn intersection(&self, o: &Rect) -> Option<Rect> {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let mx = self.max_x().min(o.max_x());
        let my = self.max_y().min(o.max_y());
        (mx > x && my > y).then(|| Rect::new(x, y, mx - x, my - y))
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.intersection(o).is_some()
    }
    pub fn area(&self) -> f64 {
        self.w * self.h
    }
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px < self.max_x() && py >= self.y && py < self.max_y()
    }
    /// Within a pixel on every edge.
    pub fn close_to(&self, o: &Rect) -> bool {
        (self.x - o.x).abs() < 1.0 && (self.y - o.y).abs() < 1.0 && (self.w - o.w).abs() < 1.0 && (self.h - o.h).abs() < 1.0
    }
}

/// Screens ordered left to right, top to bottom for equal x.
pub fn ordered(frames: &[Rect]) -> Vec<usize> {
    let mut idx: Vec<usize> = (0..frames.len()).collect();
    idx.sort_by(|&a, &b| {
        let (fa, fb) = (frames[a], frames[b]);
        if fa.x != fb.x {
            fa.x.total_cmp(&fb.x)
        } else {
            fa.y.total_cmp(&fb.y)
        }
    });
    idx
}

/// Index of the screen holding the largest part of the window.
pub fn screen_index(window: &Rect, frames: &[Rect]) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (i, f) in frames.iter().enumerate() {
        let a = f.intersection(window).map_or(0.0, |r| r.area());
        if a > 0.0 && best.is_none_or(|(_, b)| a > b) {
            best = Some((i, a));
        }
    }
    best.map(|(i, _)| i)
}

/// The screen after (or before) `current` in left-to-right order, wrapping.
pub fn adjacent(frames: &[Rect], current: usize, step: isize) -> Option<usize> {
    let order = ordered(frames);
    let slot = order.iter().position(|&i| i == current)? as isize;
    let n = order.len() as isize;
    Some(order[((slot + step) % n + n) as usize % n as usize])
}

/// Moves a window from one work area to another keeping its relative
/// position and its size (shrunk if it doesn't fit), fully inside the target.
pub fn relocate(window: &Rect, from: &Rect, to: &Rect) -> Rect {
    let w = window.w.min(to.w);
    let h = window.h.min(to.h);
    let fx = if from.w > window.w { (window.x - from.x) / (from.w - window.w) } else { 0.5 };
    let fy = if from.h > window.h { (window.y - from.y) / (from.h - window.h) } else { 0.5 };
    let x = to.x + fx.clamp(0.0, 1.0) * (to.w - w);
    let y = to.y + fy.clamp(0.0, 1.0) * (to.h - h);
    Rect::new(x.round(), y.round(), w.round(), h.round())
}

/// Centers the window in the target, shrinking it if it doesn't fit.
pub fn center(window: &Rect, target: &Rect) -> Rect {
    let w = window.w.min(target.w);
    let h = window.h.min(target.h);
    Rect::new(target.mid_x() - w / 2.0, target.mid_y() - h / 2.0, w, h).integral()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn orders_left_to_right_then_top_down() {
        let frames = [Rect::new(1920.0, 0.0, 100.0, 100.0), Rect::new(0.0, 500.0, 100.0, 100.0), Rect::new(0.0, 0.0, 100.0, 100.0)];
        assert_eq!(ordered(&frames), vec![2, 1, 0]);
    }

    #[test]
    fn picks_screen_with_largest_overlap() {
        let frames = [Rect::new(0.0, 0.0, 1920.0, 1080.0), Rect::new(1920.0, 0.0, 1920.0, 1080.0)];
        assert_eq!(screen_index(&Rect::new(1800.0, 0.0, 400.0, 300.0), &frames), Some(1));
        assert_eq!(screen_index(&Rect::new(5000.0, 0.0, 10.0, 10.0), &frames), None);
    }

    #[test]
    fn adjacent_wraps() {
        let frames = [Rect::new(1920.0, 0.0, 1920.0, 1080.0), Rect::new(0.0, 0.0, 1920.0, 1080.0)];
        assert_eq!(adjacent(&frames, 1, 1), Some(0));
        assert_eq!(adjacent(&frames, 0, 1), Some(1));
        assert_eq!(adjacent(&frames, 1, -1), Some(0));
    }

    #[test]
    fn relocate_keeps_relative_position_and_size() {
        let from = Rect::new(0.0, 0.0, 1000.0, 1000.0);
        let to = Rect::new(1000.0, 0.0, 2000.0, 1000.0);
        let moved = relocate(&Rect::new(800.0, 0.0, 200.0, 100.0), &from, &to);
        assert_eq!(moved, Rect::new(2800.0, 0.0, 200.0, 100.0));
        let big = relocate(&Rect::new(0.0, 0.0, 1500.0, 900.0), &to, &from);
        assert_eq!(big, Rect::new(0.0, 0.0, 1000.0, 900.0));
    }

    #[test]
    fn center_shrinks_to_fit() {
        let r = center(&Rect::new(0.0, 0.0, 3000.0, 500.0), &Rect::new(0.0, 0.0, 1920.0, 1080.0));
        assert_eq!(r, Rect::new(0.0, 290.0, 1920.0, 500.0));
    }
}
