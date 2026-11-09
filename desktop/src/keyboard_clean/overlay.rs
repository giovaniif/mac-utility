//! Full-screen overlay per monitor: title, countdown and an unlock switch.

use super::MonitorRect;
use eframe::egui;

/// Draws the overlays. Returns true when the unlock switch was flipped.
pub fn show(ctx: &egui::Context, monitors: &[MonitorRect], remaining: u64) -> bool {
    let mut unlock = false;
    let scale = ctx.native_pixels_per_point().unwrap_or(1.0).max(0.1);
    let fallback = [MonitorRect { x: 0, y: 0, w: 0, h: 0 }];
    let list: &[MonitorRect] = if monitors.is_empty() { &fallback } else { monitors };
    for (i, m) in list.iter().enumerate() {
        // Put the window inside the monitor; borderless fullscreen then fills
        // whichever monitor it sits on.
        let pos = egui::pos2((m.x + m.w / 4) as f32 / scale, (m.y + m.h / 4) as f32 / scale);
        let builder = egui::ViewportBuilder::default()
            .with_title("Keyboard cleaning")
            .with_decorations(false)
            .with_transparent(true)
            .with_always_on_top()
            .with_taskbar(false)
            .with_position(pos)
            .with_inner_size([800.0, 600.0])
            .with_fullscreen(true);
        let id = egui::ViewportId::from_hash_of(("keyboard_clean", i));
        ctx.show_viewport_immediate(id, builder, |ctx, _| {
            let frame = egui::Frame::none().fill(egui::Color32::from_black_alpha(217));
            egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
                if body(ui, remaining) {
                    unlock = true;
                }
            });
        });
    }
    unlock
}

fn body(ui: &mut egui::Ui, remaining: u64) -> bool {
    let mut unlock = false;
    let white = egui::Color32::WHITE;
    let gray = egui::Color32::from_gray(170);
    let h = ui.available_height();
    ui.vertical_centered(|ui| {
        ui.add_space((h / 2.0 - 140.0).max(0.0));
        ui.label(egui::RichText::new("Keyboard locked for cleaning").size(34.0).strong().color(white));
        ui.add_space(12.0);
        ui.label(egui::RichText::new(format!("Unlocks automatically in {remaining}s")).size(20.0).monospace().color(gray));
        ui.add_space(28.0);
        ui.horizontal(|ui| {
            let total = 170.0 + 16.0 + 96.0;
            ui.add_space(((ui.available_width() - total) / 2.0).max(0.0));
            ui.label(egui::RichText::new("Keyboard lock").size(24.0).color(white));
            ui.add_space(16.0);
            if switch(ui).clicked() {
                unlock = true;
            }
        });
    });
    unlock
}

/// A large "on" switch; clicking it turns the lock off.
fn switch(ui: &mut egui::Ui) -> egui::Response {
    let size = egui::vec2(96.0, 52.0);
    let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click());
    let response = response.on_hover_cursor(egui::CursorIcon::PointingHand);
    if ui.is_rect_visible(rect) {
        let r = rect.height() / 2.0;
        let fill = if response.hovered() {
            egui::Color32::from_rgb(70, 210, 105)
        } else {
            egui::Color32::from_rgb(52, 199, 89)
        };
        let p = ui.painter();
        p.rect_filled(rect, r, fill);
        p.circle_filled(egui::pos2(rect.right() - r, rect.center().y), r - 4.0, egui::Color32::WHITE);
    }
    response
}
