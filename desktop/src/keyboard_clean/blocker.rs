//! Platform keyboard blocking. `Blocker` releases the keyboard on drop;
//! `emergency_release` and the panic hook release it without the owner.

use super::MonitorRect;
use std::sync::Once;

#[cfg(windows)]
#[path = "windows.rs"]
mod platform;

#[cfg(target_os = "linux")]
#[path = "x11.rs"]
mod platform;

#[cfg(not(any(windows, target_os = "linux")))]
mod platform {
    use super::MonitorRect;

    pub struct Handle;

    pub fn start() -> Result<Handle, String> {
        Err("Keyboard cleaning isn't supported on this system".into())
    }
    pub fn stop(_: Handle) {}
    pub fn emergency_release() {}
    pub fn monitors() -> Vec<MonitorRect> {
        Vec::new()
    }
}

pub struct Blocker(Option<platform::Handle>);

impl Blocker {
    pub fn start() -> Result<Self, String> {
        platform::start().map(|h| Self(Some(h)))
    }
}

impl Drop for Blocker {
    fn drop(&mut self) {
        if let Some(h) = self.0.take() {
            platform::stop(h);
        }
    }
}

/// Releases any active block. Safe to call at any time, from any thread.
pub fn emergency_release() {
    platform::emergency_release();
}

pub fn monitors() -> Vec<MonitorRect> {
    platform::monitors()
}

/// Chains a panic hook that unblocks the keyboard before the default report.
pub fn install_panic_hook() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            platform::emergency_release();
            prev(info);
        }));
    });
}

/// True when the session is Wayland, where an X11 grab only covers XWayland apps.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn is_wayland(session_type: Option<&str>, wayland_display: Option<&str>) -> bool {
    match session_type {
        Some(t) if t.eq_ignore_ascii_case("wayland") => true,
        Some(t) if t.eq_ignore_ascii_case("x11") => false,
        _ => wayland_display.is_some_and(|d| !d.is_empty()),
    }
}

#[cfg(test)]
mod tests {
    use super::is_wayland;

    #[test]
    fn detects_wayland() {
        assert!(is_wayland(Some("wayland"), None));
        assert!(!is_wayland(Some("x11"), Some("wayland-0")));
        assert!(is_wayland(None, Some("wayland-0")));
        assert!(!is_wayland(None, Some("")));
        assert!(!is_wayland(None, None));
    }
}
