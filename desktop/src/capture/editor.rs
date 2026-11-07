//! Annotation editor window. The model and rendering live in annotate.rs;
//! this file only maps input to it and shows the rendered result.

use super::annotate::{self, Doc, Mark, Pt, Rect, Shape, Tool, COLORS, WIDTHS};
use eframe::egui;
use image::RgbaImage;

pub enum Event {
    /// Window closed; the rendered image replaces the capture.
    Close(RgbaImage),
    Save(RgbaImage),
    Copy(RgbaImage),
}

enum Drag {
    Draw { start: Pt, pts: Vec<Pt>, cur: Pt },
    Move { last: Pt },
}

pub struct Editor {
    pub cap_id: u64,
    base: RgbaImage,
    doc: Doc,
    scale: f32,
    tool: Tool,
    color: usize,
    width: usize,
    selected: Option<usize>,
    drag: Option<Drag>,
    text: Option<(Pt, String)>,
    texture: Option<egui::TextureHandle>,
    dirty: bool,
}

impl Editor {
    pub fn new(cap_id: u64, base: RgbaImage, scale: f32) -> Self {
        let doc = Doc::new(base.width(), base.height());
        Self {
            cap_id,
            base,
            doc,
            scale: scale.max(1.0),
            tool: Tool::Arrow,
            color: 0,
            width: 1,
            selected: None,
            drag: None,
            text: None,
            texture: None,
            dirty: true,
        }
    }

    fn stroke_width(&self) -> f32 {
        WIDTHS[self.width] * self.scale
    }

    fn mark(&self, shape: Shape) -> Mark {
        Mark::new(shape, COLORS[self.color], self.stroke_width())
    }

    fn draft(&self) -> Option<Mark> {
        let Some(Drag::Draw { start, pts, cur }) = &self.drag else { return None };
        let (a, b) = (*start, *cur);
        let shape = match self.tool {
            Tool::Arrow => Shape::Arrow(a, b),
            Tool::Line => Shape::Line(a, b),
            Tool::Rect => Shape::Rect(Rect::from_points(a, b)),
            Tool::Ellipse => Shape::Ellipse(Rect::from_points(a, b)),
            Tool::Pixelate => Shape::Pixelate(Rect::from_points(a, b)),
            Tool::Pen => Shape::Pen(pts.clone()),
            Tool::Highlighter => Shape::Highlighter(pts.clone()),
            _ => return None,
        };
        Some(self.mark(shape))
    }

    pub fn rendered(&self) -> RgbaImage {
        annotate::render(&self.base, &self.doc, None)
    }

    fn commit_text(&mut self) {
        if let Some((at, s)) = self.text.take() {
            if !s.trim().is_empty() {
                let size = 16.0 * self.scale + self.stroke_width() * 2.0;
                self.doc.push(self.mark(Shape::Text { at, text: s, size }));
                self.dirty = true;
            }
        }
    }

    pub fn show(&mut self, egui: &egui::Context) -> Vec<Event> {
        let mut events = Vec::new();
        let (w, h) = (self.base.width() as f32 / self.scale, self.base.height() as f32 / self.scale);
        let builder = egui::ViewportBuilder::default()
            .with_title("Annotate")
            .with_inner_size([(w + 32.0).clamp(640.0, 1400.0), (h + 90.0).clamp(400.0, 900.0)])
            .with_always_on_top()
            .with_active(true);
        egui.show_viewport_immediate(egui::ViewportId::from_hash_of(("capture-editor", self.cap_id)), builder, |ctx, _| {
            if ctx.input(|i| i.viewport().close_requested()) {
                self.commit_text();
                events.push(Event::Close(self.rendered()));
                return;
            }
            self.shortcuts(ctx, &mut events);
            egui::TopBottomPanel::top("capture-editor-tools").show(ctx, |ui| self.toolbar(ui, &mut events));
            egui::CentralPanel::default().show(ctx, |ui| self.canvas(ui));
        });
        events
    }

    fn shortcuts(&mut self, ctx: &egui::Context, events: &mut Vec<Event>) {
        use egui::{Key, KeyboardShortcut as Ks, Modifiers as M};
        if self.text.is_some() {
            return;
        }
        let (redo, undo, redo_y, save, del, back, copy) = ctx.input_mut(|i| {
            (
                i.consume_shortcut(&Ks::new(M::COMMAND | M::SHIFT, Key::Z)),
                i.consume_shortcut(&Ks::new(M::COMMAND, Key::Z)),
                i.consume_shortcut(&Ks::new(M::COMMAND, Key::Y)),
                i.consume_shortcut(&Ks::new(M::COMMAND, Key::S)),
                i.consume_key(M::NONE, Key::Delete),
                i.consume_key(M::NONE, Key::Backspace),
                i.events.iter().any(|e| matches!(e, egui::Event::Copy)),
            )
        });
        if redo || redo_y {
            self.dirty |= self.doc.redo();
            self.selected = None;
        } else if undo {
            self.dirty |= self.doc.undo();
            self.selected = None;
        }
        if del || back {
            if let Some(i) = self.selected.take() {
                self.doc.delete(i);
                self.dirty = true;
            }
        }
        if save {
            events.push(Event::Save(self.rendered()));
        }
        if copy {
            events.push(Event::Copy(self.rendered()));
        }
    }

    fn toolbar(&mut self, ui: &mut egui::Ui, events: &mut Vec<Event>) {
        ui.horizontal_wrapped(|ui| {
            for t in Tool::ALL {
                if ui.selectable_label(self.tool == t, t.label()).clicked() {
                    self.commit_text();
                    self.tool = t;
                    if t != Tool::Select {
                        self.selected = None;
                    }
                }
            }
            ui.separator();
            for (i, c) in COLORS.iter().enumerate() {
                let (r, resp) = ui.allocate_exact_size(egui::vec2(18.0, 18.0), egui::Sense::click());
                let col = egui::Color32::from_rgb(c[0], c[1], c[2]);
                ui.painter().circle_filled(r.center(), 8.0, col);
                let ring = if self.color == i { egui::Stroke::new(2.0_f32, ui.visuals().strong_text_color()) } else { egui::Stroke::new(1.0_f32, egui::Color32::GRAY) };
                ui.painter().circle_stroke(r.center(), 8.5, ring);
                if resp.clicked() {
                    self.color = i;
                    self.recolor();
                }
            }
            ui.separator();
            for (i, wd) in WIDTHS.iter().enumerate() {
                let (r, resp) = ui.allocate_exact_size(egui::vec2(22.0, 18.0), egui::Sense::click());
                if self.width == i {
                    ui.painter().rect_filled(r, 3.0, ui.visuals().selection.bg_fill);
                }
                ui.painter().line_segment([r.left_center() + egui::vec2(3.0, 0.0), r.right_center() - egui::vec2(3.0, 0.0)], egui::Stroke::new(*wd, ui.visuals().strong_text_color()));
                if resp.on_hover_text(["Thin", "Medium", "Thick"][i]).clicked() {
                    self.width = i;
                }
            }
            ui.separator();
            if ui.add_enabled(self.doc.can_undo(), egui::Button::new("Undo")).clicked() {
                self.dirty |= self.doc.undo();
                self.selected = None;
            }
            if ui.add_enabled(self.doc.can_redo(), egui::Button::new("Redo")).clicked() {
                self.dirty |= self.doc.redo();
                self.selected = None;
            }
            ui.separator();
            if ui.button("Copy").clicked() {
                events.push(Event::Copy(self.rendered()));
            }
            if ui.button("Save").clicked() {
                events.push(Event::Save(self.rendered()));
            }
        });
    }

    /// Changing the color with a mark selected recolors it, as on macOS.
    fn recolor(&mut self) {
        if let Some(i) = self.selected {
            self.dirty |= self.doc.set_color(i, COLORS[self.color]);
        }
    }

    fn canvas(&mut self, ui: &mut egui::Ui) {
        if self.dirty || self.texture.is_none() {
            let draft = self.draft();
            let img = annotate::render(&self.base, &self.doc, draft.as_ref());
            let color = egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw());
            match &mut self.texture {
                Some(t) => t.set(color, egui::TextureOptions::LINEAR),
                None => self.texture = Some(ui.ctx().load_texture("capture-editor", color, egui::TextureOptions::LINEAR)),
            }
            self.dirty = false;
        }
        let Some(tex) = self.texture.clone() else { return };
        let [tw, th] = tex.size();
        let avail = ui.available_rect_before_wrap();
        let max_k = 1.0 / ui.ctx().pixels_per_point();
        let k = (avail.width() / tw as f32).min(avail.height() / th as f32).min(max_k).max(0.01);
        let rect = egui::Rect::from_center_size(avail.center(), egui::vec2(tw as f32 * k, th as f32 * k));
        let resp = ui.allocate_rect(rect, egui::Sense::click_and_drag());
        ui.painter().image(tex.id(), rect, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);

        let origin = self.doc.origin();
        let to_img = |p: egui::Pos2| Pt::new((p.x - rect.min.x) / k + origin.x, (p.y - rect.min.y) / k + origin.y);
        let to_screen = |p: Pt| egui::pos2((p.x - origin.x) * k + rect.min.x, (p.y - origin.y) * k + rect.min.y);
        let tol = 6.0 / k;

        if self.tool == Tool::Select {
            if let Some(p) = resp.hover_pos() {
                if self.doc.hit(to_img(p), tol).is_some() {
                    ui.ctx().set_cursor_icon(egui::CursorIcon::Grab);
                }
            }
        } else if self.tool != Tool::Text && self.tool != Tool::Step {
            ui.ctx().set_cursor_icon(egui::CursorIcon::Crosshair);
        }

        if resp.drag_started() {
            if let Some(p) = resp.interact_pointer_pos().map(to_img) {
                match self.tool {
                    Tool::Select => {
                        self.selected = self.doc.hit(p, tol);
                        if self.selected.is_some() {
                            self.doc.checkpoint();
                            self.drag = Some(Drag::Move { last: p });
                        }
                    }
                    Tool::Text | Tool::Step => {}
                    _ => self.drag = Some(Drag::Draw { start: p, pts: vec![p], cur: p }),
                }
            }
        }
        if resp.dragged() {
            if let Some(p) = resp.interact_pointer_pos().map(to_img) {
                match &mut self.drag {
                    Some(Drag::Draw { pts, cur, .. }) => {
                        *cur = p;
                        if pts.last().map(|l| (l.x - p.x).abs() + (l.y - p.y).abs() > 1.0).unwrap_or(true) {
                            pts.push(p);
                        }
                        self.dirty = self.tool != Tool::Crop;
                    }
                    Some(Drag::Move { last }) => {
                        let (dx, dy) = (p.x - last.x, p.y - last.y);
                        *last = p;
                        if let Some(i) = self.selected {
                            self.doc.translate(i, dx, dy);
                            self.dirty = true;
                        }
                    }
                    None => {}
                }
            }
        }
        if resp.drag_stopped() {
            match self.drag.take() {
                Some(Drag::Draw { start, cur, .. }) if self.tool == Tool::Crop => {
                    self.doc.set_crop(Rect::from_points(start, cur));
                    self.dirty = true;
                }
                Some(d @ Drag::Draw { .. }) => {
                    self.drag = Some(d);
                    let m = self.draft();
                    self.drag = None;
                    if let Some(m) = m.filter(|m| big_enough(m)) {
                        self.doc.push(m);
                    }
                    self.dirty = true;
                }
                _ => {}
            }
        }
        if resp.clicked() {
            if let Some(p) = resp.interact_pointer_pos().map(to_img) {
                match self.tool {
                    Tool::Select => self.selected = self.doc.hit(p, tol),
                    Tool::Step => {
                        let radius = 10.0 * self.scale + self.stroke_width();
                        let n = self.doc.next_step();
                        self.doc.push(self.mark(Shape::Step { at: p, n, radius }));
                        self.dirty = true;
                    }
                    Tool::Text => {
                        self.commit_text();
                        self.text = Some((p, String::new()));
                    }
                    _ => {}
                }
            }
        }

        // Crop draft and selection outline drawn on top in screen space.
        if let (Tool::Crop, Some(Drag::Draw { start, cur, .. })) = (self.tool, &self.drag) {
            let r = egui::Rect::from_two_pos(to_screen(*start), to_screen(*cur));
            ui.painter().rect_stroke(r, 0.0, egui::Stroke::new(1.5_f32, egui::Color32::WHITE));
            ui.painter().rect_stroke(r.expand(1.5), 0.0, egui::Stroke::new(1.0_f32, egui::Color32::BLACK));
        }
        if let Some(m) = self.selected.and_then(|i| self.doc.marks().get(i)) {
            let b = m.bounds();
            let r = egui::Rect::from_min_max(to_screen(Pt::new(b.x0, b.y0)), to_screen(Pt::new(b.x1, b.y1))).expand(3.0);
            ui.painter().rect_stroke(r, 2.0, egui::Stroke::new(1.0_f32, egui::Color32::from_rgb(0, 122, 255)));
        }

        // Inline text entry.
        let mut commit = false;
        if let Some((at, s)) = &mut self.text {
            let pos = to_screen(*at);
            let c = COLORS[self.color];
            let size = ((16.0 * self.scale + WIDTHS[self.width] * self.scale * 2.0) * k).max(8.0);
            egui::Area::new(egui::Id::new("capture-editor-text")).fixed_pos(pos).order(egui::Order::Foreground).show(ui.ctx(), |ui| {
                let te = egui::TextEdit::singleline(s)
                    .font(egui::FontId::proportional(size))
                    .text_color(egui::Color32::from_rgb(c[0], c[1], c[2]))
                    .hint_text("Text")
                    .desired_width(240.0);
                let r = ui.add(te);
                r.request_focus();
                if ui.input(|i| i.key_pressed(egui::Key::Enter)) || ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                    commit = true;
                }
            });
        }
        if commit {
            self.commit_text();
        }
    }
}

fn big_enough(m: &Mark) -> bool {
    match &m.shape {
        Shape::Pen(p) | Shape::Highlighter(p) => !p.is_empty(),
        _ => {
            let b = m.bounds();
            b.width() > m.width + 2.0 || b.height() > m.width + 2.0
        }
    }
}
