//! Linux X11: XGrabKeyboard on the root window from a dedicated connection.
//! Every key event, XF86 media and volume keys included, goes to that
//! connection and is dropped. Wayland can't be blocked from a client, so it
//! refuses with a message instead.

use super::MonitorRect;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{ConnectionExt as _, GrabMode, GrabStatus};
use x11rb::CURRENT_TIME;

/// Set while a grab thread runs; clearing it makes the thread ungrab and exit.
static ACTIVE: AtomicBool = AtomicBool::new(false);

pub struct Handle {
    thread: Option<JoinHandle<()>>,
}

pub fn start() -> Result<Handle, String> {
    let session = std::env::var("XDG_SESSION_TYPE").ok();
    let wayland = std::env::var("WAYLAND_DISPLAY").ok();
    if super::is_wayland(session.as_deref(), wayland.as_deref()) {
        return Err("Keyboard lock needs X11, not Wayland".into());
    }
    if ACTIVE.load(Ordering::SeqCst) {
        return Err("Keyboard is already blocked".into());
    }
    let (conn, screen) = x11rb::connect(None).map_err(|e| format!("Couldn't reach the X server: {e}"))?;
    let root = conn.setup().roots[screen].root;

    // Another client (a menu, a game) may hold a grab briefly; retry a bit.
    let mut grabbed = false;
    for _ in 0..20 {
        let status = conn
            .grab_keyboard(false, root, CURRENT_TIME, GrabMode::ASYNC, GrabMode::ASYNC)
            .map_err(|e| e.to_string())
            .and_then(|c| c.reply().map_err(|e| e.to_string()))
            .map(|r| r.status);
        match status {
            Ok(GrabStatus::SUCCESS) => {
                grabbed = true;
                break;
            }
            Ok(_) => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => return Err(format!("Couldn't block the keyboard: {e}")),
        }
    }
    if !grabbed {
        return Err("Couldn't block the keyboard: another app holds it".into());
    }
    ACTIVE.store(true, Ordering::SeqCst);

    let thread = std::thread::Builder::new()
        .name("keyboard-clean-grab".into())
        .spawn(move || {
            while ACTIVE.load(Ordering::SeqCst) {
                // Drain and drop grabbed key events.
                while let Ok(Some(_)) = conn.poll_for_event() {}
                std::thread::sleep(Duration::from_millis(20));
            }
            let _ = conn.ungrab_keyboard(CURRENT_TIME);
            let _ = conn.flush();
        })
        .map_err(|e| {
            ACTIVE.store(false, Ordering::SeqCst);
            format!("Couldn't block the keyboard: {e}")
        })?;
    Ok(Handle { thread: Some(thread) })
}

pub fn stop(mut h: Handle) {
    ACTIVE.store(false, Ordering::SeqCst);
    if let Some(t) = h.thread.take() {
        let _ = t.join();
    }
}

/// Makes the grab thread ungrab. If the process dies first, the X server
/// drops the grab with the connection anyway.
pub fn emergency_release() {
    ACTIVE.store(false, Ordering::SeqCst);
}

pub fn monitors() -> Vec<MonitorRect> {
    let Ok((conn, screen)) = x11rb::connect(None) else { return Vec::new() };
    let root = conn.setup().roots[screen].root;
    let Ok(cookie) = conn.randr_get_monitors(root, true) else { return Vec::new() };
    let Ok(reply) = cookie.reply() else { return Vec::new() };
    reply
        .monitors
        .iter()
        .map(|m| MonitorRect { x: m.x as i32, y: m.y as i32, w: m.width as i32, h: m.height as i32 })
        .collect()
}
