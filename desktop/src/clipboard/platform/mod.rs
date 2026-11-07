//! OS glue for clipboard history: what the clipboard holds beyond its data
//! (who copied it, whether it must be skipped), change notifications, focus
//! and the synthetic Ctrl+V. Windows uses Win32, Linux uses X11; anything
//! else (macOS dev builds, Wayland) degrades to no-ops.

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(target_os = "linux")]
mod x11;
#[cfg(target_os = "linux")]
pub use self::x11::*;

#[cfg(not(any(windows, target_os = "linux")))]
mod stub;
#[cfg(not(any(windows, target_os = "linux")))]
pub use self::stub::*;

/// Facts about the current clipboard content, read next to the data itself.
#[derive(Debug, Default)]
pub struct ClipInfo {
    /// Our own paste, or content a password manager marked as hidden.
    pub skip: bool,
    /// Executable name of the app that owns the clipboard.
    pub source_app: Option<String>,
}

/// The usable area of the display under the pointer, in physical pixels,
/// with its scale factor when the OS reports one.
#[derive(Debug, Clone, Copy)]
pub struct WorkArea {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub scale: Option<f32>,
}

/// An opaque handle to a top-level window (HWND or X11 window id).
pub type WindowId = u64;
