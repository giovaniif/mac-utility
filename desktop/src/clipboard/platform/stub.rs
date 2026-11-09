//! Builds the crate on macOS for tests. Nothing here does real work.

use super::{ClipInfo, WindowId, WorkArea};

pub struct ChangeListener;

impl ChangeListener {
    pub fn new() -> Self {
        Self
    }
    /// Without notifications every poll looks at the clipboard.
    pub fn changed(&mut self) -> bool {
        true
    }
}

pub fn clipboard_info() -> ClipInfo {
    ClipInfo::default()
}

pub fn mark_own_write() {}

pub fn foreground_window() -> Option<WindowId> {
    None
}

pub fn activate(_window: WindowId) {}

pub fn send_paste() -> Result<(), String> {
    Err("Copied. Press Ctrl+V to paste".into())
}

pub fn work_area() -> Option<WorkArea> {
    None
}
