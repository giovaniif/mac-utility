//! Hosts without a port (macOS builds the crate for tests only).

use super::{GrabMode, KeyEvent, Monitor, WinId, WindowInfo};
use crate::windows::geometry::Rect;

pub fn supported() -> Result<(), String> {
    Err("Window management runs on Windows and Linux (X11)".into())
}
pub fn monitors() -> Vec<Monitor> {
    Vec::new()
}
pub fn windows() -> Vec<WindowInfo> {
    Vec::new()
}
pub fn foreground() -> Option<WinId> {
    None
}
pub fn set_frame(_id: WinId, _frame: Rect) {}
pub fn activate(_id: WinId) {}
pub fn cursor() -> Option<(f64, f64)> {
    None
}
pub fn launch(_path: &std::path::Path) {}
/// Something changed (new window, focus); the caller should poll soon.
pub fn take_dirty() -> bool {
    false
}
pub fn keys_start() {}
pub fn keys_stop() {}
pub fn keys_set_mode(_mode: GrabMode) {}
pub fn keys_poll() -> Vec<KeyEvent> {
    Vec::new()
}
/// Deliver the leader keystroke to the focused app.
pub fn pass_through(_key: char, _ctrl: bool, _shift: bool, _alt: bool) {}
