//! Builds on other hosts (macOS dev machines); recording isn't offered there.

use super::super::geom::Rect;
use super::super::keys::Stroke;
use std::path::Path;
use std::sync::mpsc::Sender;

pub fn check_session() -> Result<(), String> {
    Err("Screen recording here is only for Windows and Linux".into())
}

pub fn monitors() -> Vec<Rect> {
    Vec::new()
}

pub fn windows() -> Vec<Rect> {
    Vec::new()
}

pub fn exclude_from_capture(_title: &str) -> bool {
    true
}

pub fn display() -> String {
    String::new()
}

pub fn devices(_ffmpeg: &Path) -> (Option<String>, Option<String>) {
    (None, None)
}

pub struct KeyHook;

impl KeyHook {
    pub fn start(_tx: Sender<Stroke>) -> Option<KeyHook> {
        None
    }
}
