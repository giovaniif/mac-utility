//! Window management: moving windows between displays, and the Focus
//! window manager. Both sit on the shared window layer in `platform`.

pub mod apps;
pub mod focus;
pub mod geometry;
pub mod platform;

pub use focus::FocusFeature;

use crate::feature::{Ctx, Feature, Shortcut};
use geometry::Rect;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use platform::Monitor;

/// Ctrl+Win+→/← (Ctrl+Super on Linux): the focused window moves to the
/// next or previous display, keeping its relative position and size.
pub struct MoveDisplayFeature;

impl MoveDisplayFeature {
    pub fn new() -> Self {
        Self
    }
}

/// Where the window goes on the adjacent display (`step` is 1 or -1).
pub fn target_frame(window: &Rect, monitors: &[Monitor], step: isize) -> Result<Rect, &'static str> {
    if monitors.len() < 2 {
        return Err("Only one display");
    }
    let frames: Vec<Rect> = monitors.iter().map(|m| m.frame).collect();
    let current = geometry::screen_index(window, &frames).ok_or("The window isn't on a display")?;
    let target = geometry::adjacent(&frames, current, step).ok_or("No other display")?;
    Ok(geometry::relocate(window, &monitors[current].work, &monitors[target].work))
}

impl Feature for MoveDisplayFeature {
    fn id(&self) -> &'static str {
        "move_display"
    }
    fn title(&self) -> &'static str {
        "Move windows between displays"
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        let mods = Some(Modifiers::CONTROL | Modifiers::SUPER);
        vec![
            Shortcut { id: "next", label: "Move window to next display", default: HotKey::new(mods, Code::ArrowRight) },
            Shortcut { id: "previous", label: "Move window to previous display", default: HotKey::new(mods, Code::ArrowLeft) },
        ]
    }
    fn on_shortcut(&mut self, id: &str, ctx: &mut Ctx) {
        if let Err(msg) = platform::supported() {
            ctx.hud.push(msg);
            return;
        }
        let step = if id == "next" { 1 } else { -1 };
        let Some(fg) = platform::foreground() else {
            ctx.hud.push("No window to move".into());
            return;
        };
        let Some(win) = platform::windows().into_iter().find(|w| w.id == fg) else {
            ctx.hud.push("No window to move".into());
            return;
        };
        if win.fullscreen {
            ctx.hud.push("Can't move a full-screen window".into());
            return;
        }
        match target_frame(&win.frame, &platform::monitors(), step) {
            Ok(frame) => platform::set_frame(win.id, frame),
            Err(msg) => ctx.hud.push(msg.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mon(x: f64, w: f64) -> Monitor {
        let frame = Rect::new(x, 0.0, w, 1080.0);
        Monitor { frame, work: Rect::new(x, 0.0, w, 1040.0), primary: x == 0.0 }
    }

    #[test]
    fn moves_to_next_display_keeping_relative_place() {
        let mons = [mon(0.0, 1920.0), mon(1920.0, 2560.0)];
        let f = target_frame(&Rect::new(0.0, 0.0, 960.0, 520.0), &mons, 1).unwrap();
        assert_eq!(f, Rect::new(1920.0, 0.0, 960.0, 520.0));
        let back = target_frame(&f, &mons, 1).unwrap();
        assert_eq!(back, Rect::new(0.0, 0.0, 960.0, 520.0));
    }

    #[test]
    fn single_display_is_an_error() {
        assert_eq!(target_frame(&Rect::new(0.0, 0.0, 10.0, 10.0), &[mon(0.0, 1920.0)], 1), Err("Only one display"));
    }
}
