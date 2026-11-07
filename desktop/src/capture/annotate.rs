//! Annotation model and renderer. Pure code: no UI, no platform calls, so it
//! is unit tested and shared by the editor preview and the saved PNG.

use ab_glyph::{Font, FontRef, PxScale, ScaleFont};
use image::RgbaImage;
use tiny_skia::{FillRule, IntSize, LineCap, LineJoin, Paint, PathBuilder, Pixmap, Stroke, Transform};

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Pt {
    pub x: f32,
    pub y: f32,
}

impl Pt {
    pub fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }
}

/// Axis-aligned rectangle in image pixels; always normalized (x0 <= x1, y0 <= y1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
}

impl Rect {
    pub fn from_points(a: Pt, b: Pt) -> Self {
        Self { x0: a.x.min(b.x), y0: a.y.min(b.y), x1: a.x.max(b.x), y1: a.y.max(b.y) }
    }
    pub fn width(&self) -> f32 {
        self.x1 - self.x0
    }
    pub fn height(&self) -> f32 {
        self.y1 - self.y0
    }
    pub fn contains(&self, p: Pt) -> bool {
        p.x >= self.x0 && p.x <= self.x1 && p.y >= self.y0 && p.y <= self.y1
    }
    pub fn expand(&self, by: f32) -> Self {
        Self { x0: self.x0 - by, y0: self.y0 - by, x1: self.x1 + by, y1: self.y1 + by }
    }
    pub fn union(&self, o: &Rect) -> Self {
        Self { x0: self.x0.min(o.x0), y0: self.y0.min(o.y0), x1: self.x1.max(o.x1), y1: self.y1.max(o.y1) }
    }
    fn translate(&mut self, dx: f32, dy: f32) {
        self.x0 += dx;
        self.x1 += dx;
        self.y0 += dy;
        self.y1 += dy;
    }
    fn clamp_to(&self, w: f32, h: f32) -> Self {
        Self { x0: self.x0.clamp(0.0, w), y0: self.y0.clamp(0.0, h), x1: self.x1.clamp(0.0, w), y1: self.y1.clamp(0.0, h) }
    }
}

/// The eight palette colors, as on macOS: red, orange, yellow, green, blue, purple, black, white.
pub const COLORS: [[u8; 4]; 8] = [
    [255, 59, 48, 255],
    [255, 149, 0, 255],
    [255, 204, 0, 255],
    [52, 199, 89, 255],
    [0, 122, 255, 255],
    [175, 82, 222, 255],
    [0, 0, 0, 255],
    [255, 255, 255, 255],
];

/// Thin, medium, thick stroke widths in points (multiplied by the capture scale).
pub const WIDTHS: [f32; 3] = [2.0, 4.0, 8.0];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tool {
    Select,
    Arrow,
    Line,
    Rect,
    Ellipse,
    Pen,
    Highlighter,
    Text,
    Step,
    Pixelate,
    Crop,
}

impl Tool {
    pub const ALL: [Tool; 11] = [
        Tool::Select,
        Tool::Arrow,
        Tool::Line,
        Tool::Rect,
        Tool::Ellipse,
        Tool::Pen,
        Tool::Highlighter,
        Tool::Text,
        Tool::Step,
        Tool::Pixelate,
        Tool::Crop,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Tool::Select => "Select",
            Tool::Arrow => "Arrow",
            Tool::Line => "Line",
            Tool::Rect => "Rect",
            Tool::Ellipse => "Ellipse",
            Tool::Pen => "Pen",
            Tool::Highlighter => "Highlight",
            Tool::Text => "Text",
            Tool::Step => "Step",
            Tool::Pixelate => "Pixelate",
            Tool::Crop => "Crop",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Arrow(Pt, Pt),
    Line(Pt, Pt),
    Rect(Rect),
    Ellipse(Rect),
    Pen(Vec<Pt>),
    Highlighter(Vec<Pt>),
    Text { at: Pt, text: String, size: f32 },
    Step { at: Pt, n: u32, radius: f32 },
    Pixelate(Rect),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Mark {
    pub shape: Shape,
    pub color: [u8; 4],
    pub width: f32,
}

impl Mark {
    pub fn new(shape: Shape, color: [u8; 4], width: f32) -> Self {
        Self { shape, color, width }
    }

    pub fn bounds(&self) -> Rect {
        let pad = self.width / 2.0;
        match &self.shape {
            Shape::Arrow(a, b) => Rect::from_points(*a, *b).expand(pad + self.width * 2.0),
            Shape::Line(a, b) => Rect::from_points(*a, *b).expand(pad),
            Shape::Rect(r) | Shape::Ellipse(r) => r.expand(pad),
            Shape::Pixelate(r) => *r,
            Shape::Pen(pts) | Shape::Highlighter(pts) => {
                let mut r = Rect::from_points(pts[0], pts[0]);
                for p in pts {
                    r = r.union(&Rect::from_points(*p, *p));
                }
                let w = if matches!(self.shape, Shape::Highlighter(_)) { highlighter_width(self.width) } else { self.width };
                r.expand(w / 2.0)
            }
            Shape::Text { at, text, size } => {
                let (w, h) = measure_text(text, *size);
                Rect { x0: at.x, y0: at.y, x1: at.x + w, y1: at.y + h }
            }
            Shape::Step { at, radius, .. } => Rect { x0: at.x - radius, y0: at.y - radius, x1: at.x + radius, y1: at.y + radius },
        }
    }

    /// Whether `p` grabs this mark, with `tol` pixels of slack.
    pub fn hit(&self, p: Pt, tol: f32) -> bool {
        let reach = self.width / 2.0 + tol;
        match &self.shape {
            Shape::Arrow(a, b) | Shape::Line(a, b) => seg_dist(p, *a, *b) <= reach,
            Shape::Pen(pts) | Shape::Highlighter(pts) => {
                let reach = if matches!(self.shape, Shape::Highlighter(_)) { highlighter_width(self.width) / 2.0 + tol } else { reach };
                if pts.len() == 1 {
                    return dist(p, pts[0]) <= reach;
                }
                pts.windows(2).any(|w| seg_dist(p, w[0], w[1]) <= reach)
            }
            _ => self.bounds().expand(tol).contains(p),
        }
    }

    pub fn translate(&mut self, dx: f32, dy: f32) {
        let mv = |p: &mut Pt| {
            p.x += dx;
            p.y += dy;
        };
        match &mut self.shape {
            Shape::Arrow(a, b) | Shape::Line(a, b) => {
                mv(a);
                mv(b);
            }
            Shape::Rect(r) | Shape::Ellipse(r) | Shape::Pixelate(r) => r.translate(dx, dy),
            Shape::Pen(pts) | Shape::Highlighter(pts) => pts.iter_mut().for_each(mv),
            Shape::Text { at, .. } | Shape::Step { at, .. } => mv(at),
        }
    }
}

fn highlighter_width(w: f32) -> f32 {
    w * 4.0
}

fn dist(a: Pt, b: Pt) -> f32 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

fn seg_dist(p: Pt, a: Pt, b: Pt) -> f32 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return dist(p, a);
    }
    let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
    dist(p, Pt::new(a.x + t * dx, a.y + t * dy))
}

#[derive(Clone, Default, Debug, PartialEq)]
struct State {
    marks: Vec<Mark>,
    crop: Option<Rect>,
}

/// The editable document: marks over a base image, an optional crop, and
/// snapshot-based undo/redo.
#[derive(Clone, Debug)]
pub struct Doc {
    pub width: u32,
    pub height: u32,
    state: State,
    undo: Vec<State>,
    redo: Vec<State>,
}

impl Doc {
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height, state: State::default(), undo: Vec::new(), redo: Vec::new() }
    }
    pub fn marks(&self) -> &[Mark] {
        &self.state.marks
    }
    pub fn crop(&self) -> Option<Rect> {
        self.state.crop
    }
    /// Snapshot the current state before a change (call once per user action).
    pub fn checkpoint(&mut self) {
        self.undo.push(self.state.clone());
        self.redo.clear();
    }
    pub fn push(&mut self, mark: Mark) {
        self.checkpoint();
        self.state.marks.push(mark);
    }
    pub fn delete(&mut self, i: usize) {
        if i < self.state.marks.len() {
            self.checkpoint();
            self.state.marks.remove(i);
        }
    }
    /// Recolor a mark (undoable). Returns whether anything changed.
    pub fn set_color(&mut self, i: usize, color: [u8; 4]) -> bool {
        if self.state.marks.get(i).map_or(true, |m| m.color == color) {
            return false;
        }
        self.checkpoint();
        self.state.marks[i].color = color;
        true
    }
    /// Move a mark without a checkpoint; call `checkpoint` when the drag starts.
    pub fn translate(&mut self, i: usize, dx: f32, dy: f32) {
        if let Some(m) = self.state.marks.get_mut(i) {
            m.translate(dx, dy);
        }
    }
    /// Crop to `r` (clamped to the image). Tiny rectangles are ignored.
    pub fn set_crop(&mut self, r: Rect) -> bool {
        let r = r.clamp_to(self.width as f32, self.height as f32);
        if r.width() < 4.0 || r.height() < 4.0 {
            return false;
        }
        self.checkpoint();
        self.state.crop = Some(r);
        true
    }
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }
    pub fn undo(&mut self) -> bool {
        match self.undo.pop() {
            Some(s) => {
                self.redo.push(std::mem::replace(&mut self.state, s));
                true
            }
            None => false,
        }
    }
    pub fn redo(&mut self) -> bool {
        match self.redo.pop() {
            Some(s) => {
                self.undo.push(std::mem::replace(&mut self.state, s));
                true
            }
            None => false,
        }
    }
    /// Number for the next numbered step.
    pub fn next_step(&self) -> u32 {
        self.state.marks.iter().filter_map(|m| if let Shape::Step { n, .. } = m.shape { Some(n) } else { None }).max().unwrap_or(0) + 1
    }
    /// Topmost mark under `p`.
    pub fn hit(&self, p: Pt, tol: f32) -> Option<usize> {
        self.state.marks.iter().rposition(|m| m.hit(p, tol))
    }
    /// Top-left of the visible (cropped) area in full-image pixels.
    pub fn origin(&self) -> Pt {
        self.state.crop.map_or(Pt::default(), |c| Pt::new(c.x0.round(), c.y0.round()))
    }
}

fn font() -> FontRef<'static> {
    FontRef::try_from_slice(epaint_default_fonts::UBUNTU_LIGHT).expect("bundled font")
}

/// Width and height of a single line of text at `size` px.
pub fn measure_text(text: &str, size: f32) -> (f32, f32) {
    let f = font();
    let sf = f.as_scaled(PxScale::from(size));
    let mut w = 0.0;
    let mut prev = None;
    for c in text.chars() {
        let id = sf.glyph_id(c);
        if let Some(p) = prev {
            w += sf.kern(p, id);
        }
        w += sf.h_advance(id);
        prev = Some(id);
    }
    (w, sf.height())
}

/// Composite `doc` (plus an in-progress `extra` mark) over `base` and apply the crop.
pub fn render(base: &RgbaImage, doc: &Doc, extra: Option<&Mark>) -> RgbaImage {
    let full = render_uncropped(base, doc.marks().iter().chain(extra));
    match doc.crop() {
        Some(c) => {
            let x = c.x0.round().max(0.0) as u32;
            let y = c.y0.round().max(0.0) as u32;
            let w = (c.width().round() as u32).min(full.width().saturating_sub(x)).max(1);
            let h = (c.height().round() as u32).min(full.height().saturating_sub(y)).max(1);
            image::imageops::crop_imm(&full, x, y, w, h).to_image()
        }
        None => full,
    }
}

pub fn render_uncropped<'a>(base: &RgbaImage, marks: impl Iterator<Item = &'a Mark>) -> RgbaImage {
    let (w, h) = base.dimensions();
    let mut data = base.as_raw().clone();
    for px in data.chunks_exact_mut(4) {
        let a = px[3] as u16;
        if a != 255 {
            for c in &mut px[..3] {
                *c = ((*c as u16 * a) / 255) as u8;
            }
        }
    }
    let Some(mut pm) = IntSize::from_wh(w, h).and_then(|s| Pixmap::from_vec(data, s)) else {
        return base.clone();
    };
    for m in marks {
        draw_mark(&mut pm, m);
    }
    let mut out = RgbaImage::new(w, h);
    for (dst, src) in out.pixels_mut().zip(pm.pixels()) {
        let c = src.demultiply();
        *dst = image::Rgba([c.red(), c.green(), c.blue(), c.alpha()]);
    }
    out
}

fn paint(color: [u8; 4], alpha: f32) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color_rgba8(color[0], color[1], color[2], (color[3] as f32 * alpha) as u8);
    p.anti_alias = true;
    p
}

fn stroke(width: f32) -> Stroke {
    Stroke { width: width.max(0.5), line_cap: LineCap::Round, line_join: LineJoin::Round, ..Stroke::default() }
}

fn polyline(pts: &[Pt]) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    pb.move_to(pts.first()?.x, pts[0].y);
    if pts.len() == 1 {
        pb.line_to(pts[0].x + 0.01, pts[0].y);
    }
    for p in &pts[1..] {
        pb.line_to(p.x, p.y);
    }
    pb.finish()
}

fn sk_rect(r: &Rect) -> Option<tiny_skia::Rect> {
    tiny_skia::Rect::from_ltrb(r.x0, r.y0, r.x1.max(r.x0 + 0.5), r.y1.max(r.y0 + 0.5))
}

fn draw_mark(pm: &mut Pixmap, m: &Mark) {
    let t = Transform::identity();
    match &m.shape {
        Shape::Line(a, b) => {
            if let Some(p) = polyline(&[*a, *b]) {
                pm.stroke_path(&p, &paint(m.color, 1.0), &stroke(m.width), t, None);
            }
        }
        Shape::Arrow(a, b) => {
            let len = dist(*a, *b);
            if len < 0.5 {
                return;
            }
            let (ux, uy) = ((b.x - a.x) / len, (b.y - a.y) / len);
            let head = (m.width * 4.0 + 6.0).min(len);
            let half = head * 0.55;
            let base = Pt::new(b.x - ux * head, b.y - uy * head);
            if let Some(p) = polyline(&[*a, Pt::new(b.x - ux * head * 0.6, b.y - uy * head * 0.6)]) {
                pm.stroke_path(&p, &paint(m.color, 1.0), &stroke(m.width), t, None);
            }
            let mut pb = PathBuilder::new();
            pb.move_to(b.x, b.y);
            pb.line_to(base.x - uy * half, base.y + ux * half);
            pb.line_to(base.x + uy * half, base.y - ux * half);
            pb.close();
            if let Some(p) = pb.finish() {
                pm.fill_path(&p, &paint(m.color, 1.0), FillRule::Winding, t, None);
            }
        }
        Shape::Rect(r) => {
            if let Some(p) = sk_rect(r).map(PathBuilder::from_rect) {
                let mut s = stroke(m.width);
                s.line_cap = LineCap::Square;
                s.line_join = LineJoin::Miter;
                pm.stroke_path(&p, &paint(m.color, 1.0), &s, t, None);
            }
        }
        Shape::Ellipse(r) => {
            if let Some(p) = sk_rect(r).and_then(PathBuilder::from_oval) {
                pm.stroke_path(&p, &paint(m.color, 1.0), &stroke(m.width), t, None);
            }
        }
        Shape::Pen(pts) => {
            if let Some(p) = polyline(pts) {
                pm.stroke_path(&p, &paint(m.color, 1.0), &stroke(m.width), t, None);
            }
        }
        Shape::Highlighter(pts) => {
            if let Some(p) = polyline(pts) {
                let mut s = stroke(highlighter_width(m.width));
                s.line_cap = LineCap::Butt;
                pm.stroke_path(&p, &paint(m.color, 0.4), &s, t, None);
            }
        }
        Shape::Pixelate(r) => pixelate(pm, r, (m.width * 3.0).max(8.0) as u32),
        Shape::Text { at, text, size } => draw_text(pm, text, *at, *size, m.color),
        Shape::Step { at, n, radius } => {
            if let Some(p) = PathBuilder::from_circle(at.x, at.y, *radius) {
                pm.fill_path(&p, &paint(m.color, 1.0), FillRule::Winding, t, None);
                let ring = if m.color == [255, 255, 255, 255] { [0, 0, 0, 255] } else { [255, 255, 255, 255] };
                pm.stroke_path(&p, &paint(ring, 1.0), &stroke((radius / 8.0).max(1.0)), t, None);
                let label = n.to_string();
                let size = radius * 1.2;
                let (w, h) = measure_text(&label, size);
                draw_text(pm, &label, Pt::new(at.x - w / 2.0, at.y - h / 2.0), size, ring);
            }
        }
    }
}

fn pixelate(pm: &mut Pixmap, r: &Rect, block: u32) {
    let (w, h) = (pm.width(), pm.height());
    let r = r.clamp_to(w as f32, h as f32);
    let (x0, y0, x1, y1) = (r.x0 as u32, r.y0 as u32, r.x1.ceil() as u32, r.y1.ceil() as u32);
    let data = pm.data_mut();
    let mut by = y0;
    while by < y1 {
        let ey = (by + block).min(y1);
        let mut bx = x0;
        while bx < x1 {
            let ex = (bx + block).min(x1);
            let mut sum = [0u32; 4];
            for y in by..ey {
                for x in bx..ex {
                    let i = ((y * w + x) * 4) as usize;
                    for c in 0..4 {
                        sum[c] += data[i + c] as u32;
                    }
                }
            }
            let n = (ey - by) * (ex - bx);
            if n > 0 {
                for y in by..ey {
                    for x in bx..ex {
                        let i = ((y * w + x) * 4) as usize;
                        for c in 0..4 {
                            data[i + c] = (sum[c] / n) as u8;
                        }
                    }
                }
            }
            bx = ex;
        }
        by = ey;
    }
}

/// Draw one line of text with its top-left at `at`.
fn draw_text(pm: &mut Pixmap, text: &str, at: Pt, size: f32, color: [u8; 4]) {
    let f = font();
    let scale = PxScale::from(size);
    let sf = f.as_scaled(scale);
    let (w, h) = (pm.width() as i32, pm.height() as i32);
    let data = pm.data_mut();
    let mut x = at.x;
    let baseline = at.y + sf.ascent();
    let mut prev = None;
    for c in text.chars() {
        let id = sf.glyph_id(c);
        if let Some(p) = prev {
            x += sf.kern(p, id);
        }
        let glyph = id.with_scale_and_position(scale, ab_glyph::point(x, baseline));
        x += sf.h_advance(id);
        prev = Some(id);
        let Some(outline) = f.outline_glyph(glyph) else { continue };
        let bb = outline.px_bounds();
        outline.draw(|gx, gy, cov| {
            let px = bb.min.x as i32 + gx as i32;
            let py = bb.min.y as i32 + gy as i32;
            if px < 0 || py < 0 || px >= w || py >= h {
                return;
            }
            let a = cov.clamp(0.0, 1.0) * color[3] as f32 / 255.0;
            let i = ((py * w + px) * 4) as usize;
            for ch in 0..3 {
                data[i + ch] = (color[ch] as f32 * a + data[i + ch] as f32 * (1.0 - a)).round() as u8;
            }
            data[i + 3] = (255.0 * a + data[i + 3] as f32 * (1.0 - a)).round() as u8;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn white(w: u32, h: u32) -> RgbaImage {
        RgbaImage::from_pixel(w, h, image::Rgba([255, 255, 255, 255]))
    }

    #[test]
    fn undo_redo_round_trip() {
        let mut d = Doc::new(100, 100);
        d.push(Mark::new(Shape::Line(Pt::new(0.0, 0.0), Pt::new(10.0, 10.0)), COLORS[0], 2.0));
        d.push(Mark::new(Shape::Rect(Rect::from_points(Pt::new(5.0, 5.0), Pt::new(20.0, 20.0))), COLORS[1], 2.0));
        assert_eq!(d.marks().len(), 2);
        assert!(d.undo());
        assert_eq!(d.marks().len(), 1);
        assert!(d.redo());
        assert_eq!(d.marks().len(), 2);
        d.undo();
        d.push(Mark::new(Shape::Pen(vec![Pt::new(1.0, 1.0)]), COLORS[2], 2.0));
        assert!(!d.can_redo());
    }

    #[test]
    fn steps_number_upward() {
        let mut d = Doc::new(50, 50);
        assert_eq!(d.next_step(), 1);
        d.push(Mark::new(Shape::Step { at: Pt::new(10.0, 10.0), n: 1, radius: 8.0 }, COLORS[0], 2.0));
        d.push(Mark::new(Shape::Step { at: Pt::new(30.0, 10.0), n: 2, radius: 8.0 }, COLORS[0], 2.0));
        assert_eq!(d.next_step(), 3);
    }

    #[test]
    fn hit_picks_topmost_and_move_and_delete() {
        let mut d = Doc::new(100, 100);
        d.push(Mark::new(Shape::Rect(Rect::from_points(Pt::new(0.0, 0.0), Pt::new(50.0, 50.0))), COLORS[0], 2.0));
        d.push(Mark::new(Shape::Line(Pt::new(0.0, 25.0), Pt::new(50.0, 25.0)), COLORS[1], 2.0));
        assert_eq!(d.hit(Pt::new(25.0, 25.0), 2.0), Some(1));
        assert_eq!(d.hit(Pt::new(10.0, 10.0), 2.0), Some(0));
        assert_eq!(d.hit(Pt::new(90.0, 90.0), 2.0), None);
        d.checkpoint();
        d.translate(1, 0.0, 40.0);
        assert_eq!(d.hit(Pt::new(25.0, 65.0), 2.0), Some(1));
        assert!(d.set_color(0, COLORS[4]));
        assert!(!d.set_color(0, COLORS[4]));
        assert_eq!(d.marks()[0].color, COLORS[4]);
        d.delete(1);
        assert_eq!(d.marks().len(), 1);
        d.undo();
        assert_eq!(d.marks().len(), 2);
    }

    #[test]
    fn render_draws_rect_in_color() {
        let mut d = Doc::new(40, 40);
        d.push(Mark::new(Shape::Rect(Rect::from_points(Pt::new(10.0, 10.0), Pt::new(30.0, 30.0))), COLORS[0], 4.0));
        let out = render(&white(40, 40), &d, None);
        assert_eq!(out.get_pixel(10, 20).0, [255, 59, 48, 255]);
        assert_eq!(out.get_pixel(20, 20).0, [255, 255, 255, 255]);
        assert_eq!(out.get_pixel(0, 0).0, [255, 255, 255, 255]);
    }

    #[test]
    fn crop_changes_output_size() {
        let mut d = Doc::new(40, 30);
        assert!(!d.set_crop(Rect::from_points(Pt::new(1.0, 1.0), Pt::new(2.0, 2.0))));
        assert!(d.set_crop(Rect::from_points(Pt::new(30.0, 20.0), Pt::new(5.0, 50.0))));
        let out = render(&white(40, 30), &d, None);
        assert_eq!(out.dimensions(), (25, 10));
        assert_eq!(d.origin(), Pt::new(5.0, 20.0));
    }

    #[test]
    fn pixelate_averages_blocks() {
        let mut base = white(16, 16);
        for x in 0..8 {
            base.put_pixel(x, 0, image::Rgba([0, 0, 0, 255]));
        }
        let mut d = Doc::new(16, 16);
        d.push(Mark::new(Shape::Pixelate(Rect::from_points(Pt::new(0.0, 0.0), Pt::new(8.0, 8.0))), COLORS[0], 2.0));
        let out = render(&base, &d, None);
        let p = out.get_pixel(7, 7).0;
        assert_eq!(p, out.get_pixel(0, 0).0);
        assert!(p[0] > 200 && p[0] < 240);
        assert_eq!(out.get_pixel(12, 12).0, [255, 255, 255, 255]);
    }

    #[test]
    fn text_and_steps_paint_pixels() {
        let mut d = Doc::new(80, 40);
        d.push(Mark::new(Shape::Text { at: Pt::new(2.0, 2.0), text: "Hi".into(), size: 24.0 }, COLORS[6], 2.0));
        d.push(Mark::new(Shape::Step { at: Pt::new(60.0, 20.0), n: 1, radius: 12.0 }, COLORS[4], 2.0));
        let out = render(&white(80, 40), &d, None);
        let dark = out.pixels().filter(|p| p.0[0] < 100 && p.0[2] < 100).count();
        assert!(dark > 10, "text pixels: {dark}");
        assert_eq!(out.get_pixel(60, 14).0[..3], [0, 122, 255]);
        let (w, h) = measure_text("Hi", 24.0);
        assert!(w > 10.0 && h > 20.0);
    }

    #[test]
    fn highlighter_is_translucent() {
        let mut d = Doc::new(30, 30);
        d.push(Mark::new(Shape::Highlighter(vec![Pt::new(0.0, 15.0), Pt::new(30.0, 15.0)]), COLORS[6], 2.0));
        let out = render(&white(30, 30), &d, None);
        let p = out.get_pixel(15, 15).0;
        assert!(p[0] > 100 && p[0] < 200, "{p:?}");
    }
}
