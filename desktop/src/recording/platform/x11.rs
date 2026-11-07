//! X11 backend via x11rb: RandR monitors, the root's stacking order for
//! Space+click, and keystrokes by polling the keymap (no extension needed).
//! Wayland sessions are refused up front: x11grab can't see native windows.

use super::super::geom::Rect;
use super::super::keys::{keysym_label, Stroke};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{ConnectionExt as _, MapState};

pub fn check_session() -> Result<(), String> {
    let wayland = std::env::var("XDG_SESSION_TYPE").map(|t| t == "wayland").unwrap_or(false)
        || (std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("DISPLAY").is_none());
    if wayland {
        log::warn!("screen recording: Wayland session, x11grab would record black windows");
        return Err("Screen recording needs an X11 session".into());
    }
    if std::env::var_os("DISPLAY").is_none() {
        return Err("No X11 display".into());
    }
    Ok(())
}

pub fn monitors() -> Vec<Rect> {
    let run = || -> anyhow::Result<Vec<Rect>> {
        let (conn, n) = x11rb::connect(None)?;
        let screen = &conn.setup().roots[n];
        let root = screen.root;
        let mons = conn.randr_get_monitors(root, true)?.reply()?;
        let mut out: Vec<Rect> = mons
            .monitors
            .iter()
            .map(|m| Rect::new(i32::from(m.x), i32::from(m.y), i32::from(m.width), i32::from(m.height)))
            .collect();
        if out.is_empty() {
            out.push(Rect::new(0, 0, i32::from(screen.width_in_pixels), i32::from(screen.height_in_pixels)));
        }
        Ok(out)
    };
    run().unwrap_or_else(|e| {
        log::warn!("x11 monitors: {e}");
        Vec::new()
    })
}

/// Mapped top-level windows (WM frames), top to bottom.
pub fn windows() -> Vec<Rect> {
    let run = || -> anyhow::Result<Vec<Rect>> {
        let (conn, n) = x11rb::connect(None)?;
        let root = conn.setup().roots[n].root;
        let tree = conn.query_tree(root)?.reply()?;
        let mut out = Vec::new();
        for &w in tree.children.iter().rev() {
            let Ok(attrs) = conn.get_window_attributes(w)?.reply() else { continue };
            if attrs.map_state != MapState::VIEWABLE || attrs.override_redirect {
                continue;
            }
            let Ok(g) = conn.get_geometry(w)?.reply() else { continue };
            if g.width > 1 && g.height > 1 {
                out.push(Rect::new(i32::from(g.x), i32::from(g.y), i32::from(g.width), i32::from(g.height)));
            }
        }
        Ok(out)
    };
    run().unwrap_or_else(|e| {
        log::warn!("x11 windows: {e}");
        Vec::new()
    })
}

/// X11 has no capture exclusion; the bar is placed outside the area instead.
pub fn exclude_from_capture(_title: &str) -> bool {
    true
}

pub fn display() -> String {
    std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into())
}

/// PulseAudio default source and the first V4L2 camera.
pub fn devices(_ffmpeg: &Path) -> (Option<String>, Option<String>) {
    let cam = (0..4).map(|i| format!("/dev/video{i}")).find(|p| Path::new(p).exists());
    (cam, Some("default".into()))
}

/// Polls the X keymap every 15 ms and reports newly pressed keys.
pub struct KeyHook {
    stop: Arc<AtomicBool>,
}

impl KeyHook {
    pub fn start(tx: Sender<Stroke>) -> Option<KeyHook> {
        let (conn, _) = x11rb::connect(None).map_err(|e| log::warn!("x11 keys: {e}")).ok()?;
        let setup = conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let map = conn.get_keyboard_mapping(min, max.saturating_sub(min).saturating_add(1)).ok()?.reply().ok()?;
        let per = usize::from(map.keysyms_per_keycode.max(1));
        let sym = move |code: u8| -> u32 {
            if code < min {
                return 0;
            }
            map.keysyms.get(usize::from(code - min) * per).copied().unwrap_or(0)
        };
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::spawn(move || {
            let mut prev = [0u8; 32];
            while !flag.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(15));
                let Ok(Ok(reply)) = conn.query_keymap().map(|c| c.reply()) else { break };
                let keys = reply.keys;
                let held = |pred: &dyn Fn(u32) -> bool| {
                    (0..256usize).any(|c| keys[c / 8] & (1 << (c % 8)) != 0 && pred(sym(c as u8)))
                };
                for code in 0..256usize {
                    let bit = 1u8 << (code % 8);
                    if keys[code / 8] & bit != 0 && prev[code / 8] & bit == 0 {
                        if let Some(key) = keysym_label(sym(code as u8)) {
                            let s = Stroke {
                                ctrl: held(&|k| k == 0xffe3 || k == 0xffe4),
                                alt: held(&|k| k == 0xffe9 || k == 0xffea),
                                shift: held(&|k| k == 0xffe1 || k == 0xffe2),
                                meta: held(&|k| k == 0xffeb || k == 0xffec),
                                key,
                            };
                            if tx.send(s).is_err() {
                                return;
                            }
                        }
                    }
                }
                prev = keys;
            }
        });
        Some(KeyHook { stop })
    }
}

impl Drop for KeyHook {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}
