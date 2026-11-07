//! The window layer both window features share: enumerate, focus,
//! move/resize, monitor work areas, pointer, a modal keyboard grab, and
//! launching apps. Coordinates are physical pixels, top-left origin.
//! Win32 on Windows, EWMH over x11rb on Linux; other hosts get a stub so the
//! crate still builds (and tests run) on macOS.

use crate::windows::geometry::Rect;

pub type WinId = u32;

#[derive(Clone, Debug)]
pub struct WindowInfo {
    pub id: WinId,
    /// Stable app identity: the executable path on Windows, WM_CLASS on X11.
    pub app: String,
    /// Short name for the UI.
    pub app_name: String,
    pub title: String,
    /// Visible frame (without invisible resize borders, with decorations).
    pub frame: Rect,
    pub minimized: bool,
    pub fullscreen: bool,
    /// A normal, resizable top-level window (not a dialog, tool window or panel).
    pub normal: bool,
}

#[derive(Clone, Debug)]
pub struct Monitor {
    pub frame: Rect,
    pub work: Rect,
    pub primary: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(any(windows, target_os = "linux")), allow(dead_code))]
pub enum Key {
    /// Letters (lowercase), digits and punctuation, unshifted.
    Char(char),
    Space,
    Escape,
    Tab,
    Enter,
    Backspace,
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
}

/// What the keyboard grab does with key presses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabMode {
    /// Keys go to apps as usual.
    Off,
    /// Every key press is swallowed and queued for `keys_poll`.
    Grab,
}

#[cfg(windows)]
mod win;
#[cfg(windows)]
pub use win::*;

#[cfg(target_os = "linux")]
mod x11;
#[cfg(target_os = "linux")]
pub use x11::*;

#[cfg(not(any(windows, target_os = "linux")))]
mod stub;
#[cfg(not(any(windows, target_os = "linux")))]
pub use stub::*;

/// The primary monitor, or the first one.
pub fn primary_monitor() -> Option<Monitor> {
    let all = monitors();
    all.iter().find(|m| m.primary).cloned().or_else(|| all.into_iter().next())
}
