//! Screen rectangles in physical pixels, virtual-desktop coordinates.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Self {
        Self { x, y, w, h }
    }

    /// The rectangle spanned by two corners, in any order.
    pub fn from_corners(a: (i32, i32), b: (i32, i32)) -> Self {
        let (x0, x1) = (a.0.min(b.0), a.0.max(b.0));
        let (y0, y1) = (a.1.min(b.1), a.1.max(b.1));
        Self::new(x0, y0, x1 - x0, y1 - y0)
    }

    pub fn right(&self) -> i32 {
        self.x + self.w
    }
    pub fn bottom(&self) -> i32 {
        self.y + self.h
    }

    pub fn contains(&self, p: (i32, i32)) -> bool {
        p.0 >= self.x && p.0 < self.right() && p.1 >= self.y && p.1 < self.bottom()
    }

    pub fn union(&self, o: &Rect) -> Rect {
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        Rect::new(x, y, self.right().max(o.right()) - x, self.bottom().max(o.bottom()) - y)
    }

    pub fn intersect(&self, o: &Rect) -> Option<Rect> {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let r = self.right().min(o.right());
        let b = self.bottom().min(o.bottom());
        (r > x && b > y).then(|| Rect::new(x, y, r - x, b - y))
    }

    /// H.264 with yuv420p needs even width and height.
    pub fn even(&self) -> Rect {
        Rect::new(self.x, self.y, self.w & !1, self.h & !1)
    }
}

/// Bounding box of all displays.
pub fn virtual_bounds(monitors: &[Rect]) -> Option<Rect> {
    let mut it = monitors.iter();
    let first = *it.next()?;
    Some(it.fold(first, |acc, m| acc.union(m)))
}

/// The display containing `p`, else the first one.
pub fn monitor_at(monitors: &[Rect], p: (i32, i32)) -> Option<Rect> {
    monitors.iter().find(|m| m.contains(p)).or(monitors.first()).copied()
}

/// Topmost window under `p`; `windows` is ordered top to bottom.
pub fn window_at(windows: &[Rect], p: (i32, i32)) -> Option<Rect> {
    windows.iter().find(|w| w.contains(p)).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corners_normalize() {
        assert_eq!(Rect::from_corners((50, 80), (10, 20)), Rect::new(10, 20, 40, 60));
    }

    #[test]
    fn even_rounds_down() {
        assert_eq!(Rect::new(3, 4, 101, 99).even(), Rect::new(3, 4, 100, 98));
    }

    #[test]
    fn lookups() {
        let mons = [Rect::new(0, 0, 1920, 1080), Rect::new(1920, -200, 2560, 1440)];
        assert_eq!(virtual_bounds(&mons), Some(Rect::new(0, -200, 4480, 1440)));
        assert_eq!(monitor_at(&mons, (2000, 0)), Some(mons[1]));
        assert_eq!(monitor_at(&mons, (-5, -5)), Some(mons[0]));
        let wins = [Rect::new(100, 100, 200, 200), Rect::new(0, 0, 1000, 1000)];
        assert_eq!(window_at(&wins, (150, 150)), Some(wins[0]));
        assert_eq!(window_at(&wins, (500, 500)), Some(wins[1]));
        assert_eq!(window_at(&wins, (5000, 500)), None);
        assert_eq!(mons[0].intersect(&Rect::new(1900, 10, 100, 10)), Some(Rect::new(1900, 10, 20, 10)));
    }
}
