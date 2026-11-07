//! Quick-access thumbnail stack in the bottom-left corner of the monitor
//! under the pointer. Hover for actions; double-click to annotate.

use super::grab;
use eframe::egui;
use image::RgbaImage;
use std::path::PathBuf;

pub struct Capture {
    pub id: u64,
    pub image: RgbaImage,
    /// The PNG in the cache folder (removed when the capture goes away).
    pub cache_path: PathBuf,
    /// Where the user saved it, once they did.
    pub saved_path: Option<PathBuf>,
    pub scale: f32,
    pub texture: Option<egui::TextureHandle>,
}

impl Capture {
    pub fn texture(&mut self, ctx: &egui::Context) -> egui::TextureHandle {
        let img = &self.image;
        let id = self.id;
        self.texture
            .get_or_insert_with(|| {
                let color = egui::ColorImage::from_rgba_unmultiplied([img.width() as usize, img.height() as usize], img.as_raw());
                ctx.load_texture(format!("capture-{id}"), color, egui::TextureOptions::LINEAR)
            })
            .clone()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Copy(u64),
    Save(u64),
    Trash(u64),
    Close(u64),
    Edit(u64),
}

const THUMB_W: f32 = 220.0;
const GAP: f32 = 10.0;
const MARGIN: f32 = 20.0;

/// Thumbnail height for an image, clamped so very tall or wide captures stay usable.
pub fn thumb_height(w: u32, h: u32) -> f32 {
    (THUMB_W * h as f32 / w.max(1) as f32).clamp(60.0, 220.0)
}

/// Total stack height for these image sizes, newest at the bottom.
pub fn stack_height(sizes: &[(u32, u32)]) -> f32 {
    sizes.iter().map(|(w, h)| thumb_height(*w, *h)).sum::<f32>() + GAP * sizes.len().saturating_sub(1) as f32
}

pub fn show(egui: &egui::Context, caps: &mut [Capture]) -> Vec<Action> {
    let mut actions = Vec::new();
    if caps.is_empty() {
        return actions;
    }
    let sizes: Vec<(u32, u32)> = caps.iter().map(|c| c.image.dimensions()).collect();
    let height = stack_height(&sizes);
    let mut builder = egui::ViewportBuilder::default()
        .with_title("Captures")
        .with_inner_size([THUMB_W, height])
        .with_decorations(false)
        .with_transparent(true)
        .with_resizable(false)
        .with_always_on_top()
        .with_taskbar(false);
    if let Some(m) = grab::pointer_monitor_rect() {
        let s = m.scale;
        let x = m.x as f32 / s + MARGIN;
        let y = (m.y as f32 + m.height as f32) / s - height - MARGIN - 40.0;
        builder = builder.with_position([x, y]);
    }
    egui.show_viewport_immediate(egui::ViewportId::from_hash_of("capture-stack"), builder, |ctx, _| {
        egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
            ui.spacing_mut().item_spacing = egui::vec2(0.0, GAP);
            for c in caps.iter_mut() {
                let (w, h) = c.image.dimensions();
                let size = egui::vec2(THUMB_W, thumb_height(w, h));
                let (rect, resp) = ui.allocate_exact_size(size, egui::Sense::click());
                let tex = c.texture(ctx);
                let painter = ui.painter();
                painter.rect_filled(rect, 8.0, egui::Color32::from_gray(30));
                let fit = fit_rect(rect.shrink(3.0), w, h);
                painter.image(tex.id(), fit, egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)), egui::Color32::WHITE);
                if resp.double_clicked() {
                    actions.push(Action::Edit(c.id));
                }
                if !ui.rect_contains_pointer(rect) {
                    continue;
                }
                painter.rect_filled(rect, 8.0, egui::Color32::from_black_alpha(130));
                let center = rect.center();
                let big = egui::vec2(80.0, 26.0);
                if ui.put(egui::Rect::from_center_size(center - egui::vec2(0.0, 16.0), big), egui::Button::new("Copy")).clicked() {
                    actions.push(Action::Copy(c.id));
                }
                if ui.put(egui::Rect::from_center_size(center + egui::vec2(0.0, 16.0), big), egui::Button::new("Save")).clicked() {
                    actions.push(Action::Save(c.id));
                }
                let small = egui::vec2(24.0, 22.0);
                let corner = |dx: f32, dy: f32| egui::Rect::from_center_size(egui::pos2(dx, dy), small);
                if ui.put(corner(rect.min.x + 16.0, rect.min.y + 15.0), egui::Button::new("✖")).on_hover_text("Close").clicked() {
                    actions.push(Action::Close(c.id));
                }
                if ui.put(corner(rect.max.x - 16.0, rect.min.y + 15.0), egui::Button::new("✏")).on_hover_text("Annotate").clicked() {
                    actions.push(Action::Edit(c.id));
                }
                if ui.put(corner(rect.max.x - 16.0, rect.max.y - 15.0), egui::Button::new("🗑")).on_hover_text("Trash").clicked() {
                    actions.push(Action::Trash(c.id));
                }
            }
        });
    });
    actions
}

/// Largest rect with the image's aspect ratio centered in `r`.
pub fn fit_rect(r: egui::Rect, w: u32, h: u32) -> egui::Rect {
    let k = (r.width() / w.max(1) as f32).min(r.height() / h.max(1) as f32);
    egui::Rect::from_center_size(r.center(), egui::vec2(w as f32 * k, h as f32 * k))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbs_keep_aspect_within_bounds() {
        assert_eq!(thumb_height(1920, 1080), 220.0 * 1080.0 / 1920.0);
        assert_eq!(thumb_height(100, 10_000), 220.0);
        assert_eq!(thumb_height(10_000, 10), 60.0);
        assert_eq!(stack_height(&[(1920, 1080), (1920, 1080)]), 2.0 * 123.75 + GAP);
    }

    #[test]
    fn fit_centers_and_preserves_ratio() {
        let r = fit_rect(egui::Rect::from_min_size(egui::pos2(0.0, 0.0), egui::vec2(100.0, 100.0)), 200, 100);
        assert_eq!(r.size(), egui::vec2(100.0, 50.0));
        assert_eq!(r.center(), egui::pos2(50.0, 50.0));
    }
}
