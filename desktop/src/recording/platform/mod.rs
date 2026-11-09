//! Per-OS pieces: displays, windows for Space+click, the keystroke source,
//! capture exclusion and default devices. Each backend exposes the same
//! functions: `check_session`, `monitors`, `windows`, `exclude_from_capture`,
//! `display`, `devices` and `KeyHook`.

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
