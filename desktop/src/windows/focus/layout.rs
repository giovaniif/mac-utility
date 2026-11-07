//! Frame math for the stage, in screen pixels (top-left origin). Port of
//! StageLayout.swift.

use super::stage::{FocusSet, SetLayout, SplitAxis, WindowId};
use crate::windows::geometry::Rect;
use std::collections::HashMap;

pub struct StageLayout {
    /// The managed display's work area (no taskbar or panels).
    pub stage: Rect,
    pub gap: f64,
    /// A lone window stops growing at this width and centers.
    pub width_cap: f64,
}

impl StageLayout {
    pub fn inner(&self) -> Rect {
        self.stage.inset(self.gap, self.gap).integral()
    }

    /// Frames for the windows that are visible; the rest get parked.
    pub fn frames(&self, set: &FocusSet, zoomed: Option<WindowId>) -> HashMap<WindowId, Rect> {
        if let Some(z) = zoomed {
            if set.windows.contains(&z) {
                return HashMap::from([(z, self.inner())]);
            }
        }
        match set.windows.len() {
            0 => HashMap::new(),
            1 => HashMap::from([(set.windows[0], self.single())]),
            _ => {
                if set.layout == SetLayout::Stacked {
                    return HashMap::from([(set.focused.unwrap_or(set.windows[0]), self.single())]);
                }
                let (a, b) = self.split(set.ratio, set.axis);
                HashMap::from([(set.windows[0], a), (set.windows[1], b)])
            }
        }
    }

    pub fn single(&self) -> Rect {
        let inner = self.inner();
        let width = inner.w.min(self.width_cap);
        Rect::new((inner.mid_x() - width / 2.0).round(), inner.y, width.round(), inner.h)
    }

    /// First and second pane: left and right, or top and bottom.
    pub fn split(&self, ratio: f64, axis: SplitAxis) -> (Rect, Rect) {
        let inner = self.inner();
        let gap = self.gap;
        match axis {
            SplitAxis::Vertical => {
                let lw = ((inner.w - gap) * ratio).round();
                let left = Rect::new(inner.x, inner.y, lw, inner.h);
                let right = Rect::new(left.max_x() + gap, inner.y, inner.max_x() - left.max_x() - gap, inner.h);
                (left, right)
            }
            SplitAxis::Horizontal => {
                let th = ((inner.h - gap) * ratio).round();
                let top = Rect::new(inner.x, inner.y, inner.w, th);
                let bottom = Rect::new(inner.x, top.max_y() + gap, inner.w, inner.max_y() - top.max_y() - gap);
                (top, bottom)
            }
        }
    }

    /// The split ratio implied by the user resizing one pane to `size`.
    pub fn ratio_for(&self, w: f64, h: f64, is_first: bool, axis: SplitAxis) -> f64 {
        let inner = self.inner();
        let usable = if axis == SplitAxis::Vertical { inner.w } else { inner.h } - self.gap;
        if usable <= 0.0 {
            return 0.5;
        }
        let share = if axis == SplitAxis::Vertical { w } else { h } / usable;
        if is_first {
            share
        } else {
            1.0 - share
        }
    }

    /// The ratio for a divider dragged to screen point `p` (x or y).
    pub fn ratio_at(&self, p: f64, axis: SplitAxis) -> f64 {
        let inner = self.inner();
        let (start, len) = if axis == SplitAxis::Vertical { (inner.x, inner.w) } else { (inner.y, inner.h) };
        let usable = len - self.gap;
        if usable <= 0.0 {
            return 0.5;
        }
        (p - start - self.gap / 2.0) / usable
    }

    /// Where a parked window goes: a corner of the managed display with a
    /// 1 px sliver left on screen. Picks the corner whose off-screen side
    /// overlaps other displays least.
    pub fn parking_origin(w: f64, h: f64, display: &Rect, others: &[Rect]) -> (f64, f64) {
        let candidates = [(display.max_x() - 1.0, display.max_y() - 1.0), (display.x - w + 1.0, display.max_y() - 1.0)];
        let overlap = |(x, y): (f64, f64)| -> f64 {
            let r = Rect::new(x, y, w, h);
            others.iter().filter_map(|o| r.intersection(o)).map(|i| i.area()).sum()
        };
        let mut best = candidates[0];
        for c in candidates {
            if overlap(c) < overlap(best) {
                best = c;
            }
        }
        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn laptop() -> StageLayout {
        StageLayout { stage: Rect::new(0.0, 24.0, 1440.0, 876.0), gap: 12.0, width_cap: 1440.0 }
    }
    fn desktop() -> StageLayout {
        StageLayout { stage: Rect::new(0.0, 25.0, 1920.0, 1055.0), gap: 12.0, width_cap: 1440.0 }
    }
    fn set(ids: &[WindowId]) -> FocusSet {
        let mut s = FocusSet::default();
        for &i in ids {
            s.insert(i);
        }
        s
    }

    #[test]
    fn single_window_fills_laptop_stage() {
        assert_eq!(laptop().frames(&set(&[1]), None)[&1], Rect::new(12.0, 36.0, 1416.0, 852.0));
    }

    #[test]
    fn single_window_is_capped_and_centered_on_desktop() {
        assert_eq!(desktop().frames(&set(&[1]), None)[&1], Rect::new(240.0, 37.0, 1440.0, 1031.0));
    }

    #[test]
    fn split_uses_full_width_with_gap() {
        let f = desktop().frames(&set(&[1, 2]), None);
        let (l, r) = (f[&1], f[&2]);
        assert_eq!(l.x, 12.0);
        assert_eq!(r.x - l.max_x(), 12.0);
        assert_eq!(r.max_x(), 1908.0);
        assert!((l.w - r.w).abs() <= 1.0);
    }

    #[test]
    fn stacked_shows_only_focused() {
        let mut s = set(&[1, 2]);
        s.layout = SetLayout::Stacked;
        s.focused = Some(2);
        let keys: Vec<_> = laptop().frames(&s, None).into_keys().collect();
        assert_eq!(keys, vec![2]);
    }

    #[test]
    fn zoom_fills_inner_stage_without_cap() {
        let d = desktop();
        assert_eq!(d.frames(&set(&[1, 2]), Some(2)), HashMap::from([(2, d.inner())]));
    }

    #[test]
    fn horizontal_split_stacks_top_and_bottom() {
        let mut s = set(&[1, 2]);
        s.axis = SplitAxis::Horizontal;
        let l = laptop();
        let f = l.frames(&s, None);
        let (t, b) = (f[&1], f[&2]);
        assert_eq!(t.w, l.inner().w);
        assert_eq!(b.y - t.max_y(), 12.0);
        assert_eq!(b.max_y(), l.inner().max_y());
    }

    #[test]
    fn ratio_from_resize() {
        let l = laptop();
        let (left, _) = l.split(0.5, SplitAxis::Vertical);
        assert!((l.ratio_for(left.w, left.h, true, SplitAxis::Vertical) - 0.5).abs() < 0.01);
        assert!((l.ratio_for(left.w, left.h, false, SplitAxis::Vertical) - 0.5).abs() < 0.01);
    }

    #[test]
    fn ratio_from_divider_position() {
        let l = laptop();
        let (left, _) = l.split(0.5, SplitAxis::Vertical);
        assert!((l.ratio_at(left.max_x() + 6.0, SplitAxis::Vertical) - 0.5).abs() < 0.01);
    }

    #[test]
    fn parking_avoids_other_displays() {
        let main = Rect::new(0.0, 0.0, 1920.0, 1080.0);
        let right = Rect::new(1920.0, 600.0, 1512.0, 982.0);
        assert_eq!(StageLayout::parking_origin(800.0, 600.0, &main, &[right]), (-799.0, 1079.0));
        assert_eq!(StageLayout::parking_origin(800.0, 600.0, &main, &[]), (1919.0, 1079.0));
    }
}
