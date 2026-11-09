//! Crosshair area selection over frozen monitor images: drag for an area
//! with a live size label, Space then click a window, Esc cancels.

use super::grab::{self, Shot, WinRect};
use eframe::egui;
use image::RgbaImage;

pub enum Outcome {
    Pending,
    Cancel,
    /// The captured pixels and the scale of the monitor they came from.
    Done(RgbaImage, f32),
}

pub struct Selector {
    shots: Vec<Shot>,
    textures: Vec<Option<egui::TextureHandle>>,
    /// (monitor index, start, current) in image pixels of that monitor.
    drag: Option<(usize, egui::Pos2, egui::Pos2)>,
    window_mode: bool,
    windows: Vec<WinRect>,
}

impl Selector {
    pub fn new(shots: Vec<Shot>) -> Self {
        let n = shots.len();
        Self { shots, textures: (0..n).map(|_| None).collect(), drag: None, window_mode: false, windows: Vec::new() }
    }

    pub fn show(&mut self, egui: &egui::Context) -> Outcome {
        let mut outcome = Outcome::Pending;
        for i in 0..self.shots.len() {
            let (x, y, w, h, scale) = {
                let s = &self.shots[i];
                (s.x as f32, s.y as f32, s.width as f32, s.height as f32, s.scale)
            };
            let builder = egui::ViewportBuilder::default()
                .with_title("Capture")
                .with_position([x / scale, y / scale])
                .with_inner_size([w / scale, h / scale])
                .with_decorations(false)
                .with_resizable(false)
                .with_always_on_top()
                .with_taskbar(false)
                .with_active(true);
            let id = egui::ViewportId::from_hash_of(("capture-selector", i));
            egui.show_viewport_immediate(id, builder, |ctx, _| {
                if let o @ (Outcome::Cancel | Outcome::Done(..)) = self.monitor_ui(ctx, i) {
                    outcome = o;
                }
            });
            if !matches!(outcome, Outcome::Pending) {
                break;
            }
        }
        outcome
    }

    fn monitor_ui(&mut self, ctx: &egui::Context, i: usize) -> Outcome {
        if ctx.input(|inp| inp.key_pressed(egui::Key::Escape) || inp.viewport().close_requested()) {
            return Outcome::Cancel;
        }
        if ctx.input(|inp| inp.key_pressed(egui::Key::Space)) {
            self.window_mode = !self.window_mode;
            self.drag = None;
            if self.window_mode && self.windows.is_empty() {
                self.windows = grab::window_rects();
            }
        }
        let tex = self.textures[i]
            .get_or_insert_with(|| {
                let img = &self.shots[i].image;
                let color = egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw());
                ctx.load_texture(format!("capture-frozen-{i}"), color, egui::TextureOptions::LINEAR)
            })
            .clone();
        let mut outcome = Outcome::Pending;
        egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
            let rect = ui.max_rect();
            let resp = ui.allocate_rect(rect, egui::Sense::click_and_drag());
            let painter = ui.painter();
            painter.image(tex.id(), rect, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);
            let shot = &self.shots[i];
            // Image pixels per point inside this viewport.
            let k = shot.image.width() as f32 / rect.width().max(1.0);
            let to_img = |p: egui::Pos2| ((p - rect.min) * k).to_pos2();
            let to_screen = |p: egui::Pos2| rect.min + p.to_vec2() / k;
            let dim = egui::Color32::from_black_alpha(90);
            let accent = egui::Color32::from_rgb(0, 122, 255);
            let pointer = resp.hover_pos().or_else(|| ctx.pointer_latest_pos());

            if self.window_mode {
                ctx.set_cursor_icon(egui::CursorIcon::PointingHand);
                // Desktop pixels per image pixel.
                let gx = shot.width as f32 / shot.image.width().max(1) as f32;
                let hovered = pointer.and_then(|p| {
                    let ip = to_img(p);
                    let dx = shot.x + (ip.x * gx) as i32;
                    let dy = shot.y + (ip.y * gx) as i32;
                    grab::window_at(&self.windows, dx, dy).cloned()
                });
                painter.rect_filled(rect, 0.0, dim);
                if let Some(win) = &hovered {
                    let a = to_screen(egui::pos2((win.x - shot.x) as f32 / gx, (win.y - shot.y) as f32 / gx));
                    let b = to_screen(egui::pos2((win.x - shot.x + win.width as i32) as f32 / gx, (win.y - shot.y + win.height as i32) as f32 / gx));
                    let wr = egui::Rect::from_min_max(a, b).intersect(rect);
                    painter.image(tex.id(), wr, uv(rect, wr), egui::Color32::WHITE);
                    painter.rect_filled(wr, 0.0, egui::Color32::from_rgba_unmultiplied(0, 122, 255, 50));
                    if resp.clicked() {
                        if let Some(img) = grab::crop_shot(shot, win.x, win.y, win.width, win.height) {
                            outcome = Outcome::Done(img, shot.scale);
                        }
                    }
                }
                hint(painter, rect, "Click a window · Space for area · Esc to cancel");
                return;
            }

            ctx.set_cursor_icon(egui::CursorIcon::Crosshair);
            if resp.drag_started() {
                if let Some(p) = resp.interact_pointer_pos() {
                    self.drag = Some((i, to_img(p), to_img(p)));
                }
            }
            if let (Some((di, _, cur)), Some(p)) = (&mut self.drag, resp.interact_pointer_pos()) {
                if *di == i && resp.dragged() {
                    *cur = to_img(p);
                }
            }
            let sel = self.drag.filter(|d| d.0 == i).map(|(_, a, b)| {
                let r = egui::Rect::from_two_pos(a, b);
                let max = egui::pos2(shot.image.width() as f32, shot.image.height() as f32);
                egui::Rect::from_min_max(r.min.max(egui::Pos2::ZERO).round(), r.max.min(max).round())
            });
            match sel {
                Some(r) => {
                    let sr = egui::Rect::from_min_max(to_screen(r.min), to_screen(r.max));
                    for part in outside(rect, sr) {
                        painter.rect_filled(part, 0.0, dim);
                    }
                    painter.rect_stroke(sr, 0.0, egui::Stroke::new(1.0_f32, egui::Color32::WHITE));
                    let label = format!("{} × {}", r.width() as u32, r.height() as u32);
                    size_label(painter, sr.right_bottom() + egui::vec2(8.0, 8.0), rect, &label, accent);
                }
                None => {
                    painter.rect_filled(rect, 0.0, egui::Color32::from_black_alpha(30));
                }
            }
            if let Some(p) = pointer {
                let s = egui::Stroke::new(1.0_f32, egui::Color32::from_white_alpha(140));
                painter.hline(rect.x_range(), p.y, s);
                painter.vline(p.x, rect.y_range(), s);
                if sel.is_none() {
                    let ip = to_img(p);
                    size_label(painter, p + egui::vec2(12.0, 12.0), rect, &format!("{}, {}", ip.x as i32, ip.y as i32), accent);
                }
            }
            if resp.drag_stopped() {
                if let Some(r) = sel {
                    if r.width() >= 3.0 && r.height() >= 3.0 {
                        let img = image::imageops::crop_imm(&shot.image, r.min.x as u32, r.min.y as u32, r.width() as u32, r.height() as u32).to_image();
                        outcome = Outcome::Done(img, shot.scale);
                    }
                }
                self.drag = None;
            }
        });
        outcome
    }
}

fn uv(full: egui::Rect, part: egui::Rect) -> egui::Rect {
    let f = |p: egui::Pos2| egui::pos2((p.x - full.min.x) / full.width(), (p.y - full.min.y) / full.height());
    egui::Rect::from_min_max(f(part.min), f(part.max))
}

/// The four rectangles of `full` around `hole`.
fn outside(full: egui::Rect, hole: egui::Rect) -> [egui::Rect; 4] {
    [
        egui::Rect::from_min_max(full.min, egui::pos2(full.max.x, hole.min.y)),
        egui::Rect::from_min_max(egui::pos2(full.min.x, hole.max.y), full.max),
        egui::Rect::from_min_max(egui::pos2(full.min.x, hole.min.y), egui::pos2(hole.min.x, hole.max.y)),
        egui::Rect::from_min_max(egui::pos2(hole.max.x, hole.min.y), egui::pos2(full.max.x, hole.max.y)),
    ]
}

fn size_label(painter: &egui::Painter, at: egui::Pos2, bounds: egui::Rect, text: &str, bg: egui::Color32) {
    let galley = painter.layout_no_wrap(text.to_string(), egui::FontId::proportional(13.0), egui::Color32::WHITE);
    let size = galley.size() + egui::vec2(12.0, 6.0);
    let mut min = at;
    if min.x + size.x > bounds.max.x {
        min.x = bounds.max.x - size.x - 4.0;
    }
    if min.y + size.y > bounds.max.y {
        min.y = bounds.max.y - size.y - 4.0;
    }
    let r = egui::Rect::from_min_size(min, size);
    painter.rect_filled(r, 4.0, bg);
    painter.galley(r.min + egui::vec2(6.0, 3.0), galley, egui::Color32::WHITE);
}

fn hint(painter: &egui::Painter, rect: egui::Rect, text: &str) {
    let galley = painter.layout_no_wrap(text.to_string(), egui::FontId::proportional(15.0), egui::Color32::WHITE);
    let size = galley.size() + egui::vec2(20.0, 10.0);
    let r = egui::Rect::from_center_size(egui::pos2(rect.center().x, rect.min.y + 40.0), size);
    painter.rect_filled(r, 6.0, egui::Color32::from_black_alpha(180));
    painter.galley(r.min + egui::vec2(10.0, 5.0), galley, egui::Color32::WHITE);
}
