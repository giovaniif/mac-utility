//! X11 via x11rb: clipboard TARGETS (password-manager hint), owner process,
//! _NET_ACTIVE_WINDOW focus restore and XTest Ctrl+V. On a Wayland session
//! synthetic input and focus changes aren't allowed, so those degrade.

use super::{ClipInfo, WindowId, WorkArea};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ClientMessageEvent, ConnectionExt as _, CreateWindowAux, EventMask, Window, WindowClass,
    KEY_PRESS_EVENT, KEY_RELEASE_EVENT,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::{COPY_DEPTH_FROM_PARENT, COPY_FROM_PARENT, CURRENT_TIME, NONE};

const PASSWORD_HINT: &str = "x-kde-passwordManagerHint";

pub fn is_wayland() -> bool {
    std::env::var("XDG_SESSION_TYPE").map_or(false, |s| s.eq_ignore_ascii_case("wayland"))
        || (std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("DISPLAY").is_none())
}

fn connect() -> Option<(RustConnection, Window)> {
    let (conn, screen) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots.get(screen)?.root;
    Some((conn, root))
}

fn atom(conn: &RustConnection, name: &str) -> Option<Atom> {
    Some(conn.intern_atom(false, name.as_bytes()).ok()?.reply().ok()?.atom)
}

fn property32(conn: &RustConnection, window: Window, name: &str, kind: AtomEnum) -> Option<u32> {
    let prop = atom(conn, name)?;
    let reply = conn.get_property(false, window, prop, kind, 0, 1).ok()?.reply().ok()?;
    let mut values = reply.value32()?;
    values.next()
}

/// Polling stands in for XFixes selection events.
pub struct ChangeListener;

impl ChangeListener {
    pub fn new() -> Self {
        Self
    }
    pub fn changed(&mut self) -> bool {
        true
    }
}

pub fn clipboard_info() -> ClipInfo {
    let Some((conn, root)) = connect() else { return ClipInfo::default() };
    let skip = match (targets(&conn, root), atom(&conn, PASSWORD_HINT)) {
        (Some(targets), Some(hint)) => targets.contains(&hint),
        _ => false,
    };
    let source_app = if is_wayland() { None } else { owner_app(&conn, root) };
    ClipInfo { skip, source_app }
}

/// Asks the clipboard owner for its TARGETS list.
fn targets(conn: &RustConnection, root: Window) -> Option<Vec<Atom>> {
    let clipboard = atom(conn, "CLIPBOARD")?;
    let targets = atom(conn, "TARGETS")?;
    let prop = atom(conn, "MACUTILITY_TARGETS")?;
    let win = conn.generate_id().ok()?;
    conn.create_window(
        COPY_DEPTH_FROM_PARENT,
        win,
        root,
        0,
        0,
        1,
        1,
        0,
        WindowClass::INPUT_OUTPUT,
        COPY_FROM_PARENT,
        &CreateWindowAux::new(),
    )
    .ok()?;
    let result = (|| {
        conn.convert_selection(win, clipboard, targets, prop, CURRENT_TIME).ok()?;
        conn.flush().ok()?;
        let deadline = Instant::now() + Duration::from_millis(150);
        while Instant::now() < deadline {
            match conn.poll_for_event() {
                Ok(Some(Event::SelectionNotify(e))) if e.requestor == win => {
                    if e.property == NONE {
                        return None;
                    }
                    let reply = conn.get_property(true, win, prop, AtomEnum::ATOM, 0, 4096).ok()?.reply().ok()?;
                    return Some(reply.value32()?.collect::<Vec<Atom>>());
                }
                Ok(Some(_)) => {}
                Ok(None) => std::thread::sleep(Duration::from_millis(2)),
                Err(_) => return None,
            }
        }
        None
    })();
    let _ = conn.destroy_window(win);
    let _ = conn.flush();
    result
}

fn owner_app(conn: &RustConnection, root: Window) -> Option<String> {
    let clipboard = atom(conn, "CLIPBOARD")?;
    let owner = conn.get_selection_owner(clipboard).ok()?.reply().ok()?.owner;
    let pid = Some(owner)
        .filter(|w| *w != NONE)
        .and_then(|w| property32(conn, w, "_NET_WM_PID", AtomEnum::CARDINAL))
        .or_else(|| {
            let active = property32(conn, root, "_NET_ACTIVE_WINDOW", AtomEnum::WINDOW)?;
            property32(conn, active, "_NET_WM_PID", AtomEnum::CARDINAL)
        })?;
    let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
    Some(comm.trim().to_string())
}

/// arboard can't add a custom target on X11; the watcher resyncs after our
/// own writes instead.
pub fn mark_own_write() {}

pub fn foreground_window() -> Option<WindowId> {
    if is_wayland() {
        return None;
    }
    let (conn, root) = connect()?;
    property32(&conn, root, "_NET_ACTIVE_WINDOW", AtomEnum::WINDOW)
        .filter(|w| *w != NONE)
        .map(WindowId::from)
}

pub fn activate(window: WindowId) {
    if is_wayland() {
        return;
    }
    let Some((conn, root)) = connect() else { return };
    let Some(net_active) = atom(&conn, "_NET_ACTIVE_WINDOW") else { return };
    let Ok(window) = Window::try_from(window) else { return };
    // Source 2 = pager, which window managers honor without focus-stealing checks.
    let event = ClientMessageEvent::new(32, window, net_active, [2u32, CURRENT_TIME, 0, 0, 0]);
    let mask = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
    let _ = conn.send_event(false, root, mask, event);
    let _ = conn.flush();
}

pub fn send_paste() -> Result<(), String> {
    if is_wayland() {
        return Err("Copied. Press Ctrl+V to paste".into());
    }
    let (conn, root) = connect().ok_or("Copied. No X display to paste into")?;
    let fail = || "Copied. Press Ctrl+V to paste".to_string();
    let setup = conn.setup();
    let (min, max) = (setup.min_keycode, setup.max_keycode);
    let map = conn.get_keyboard_mapping(min, max - min + 1).map_err(|_| fail())?.reply().map_err(|_| fail())?;
    let per = usize::from(map.keysyms_per_keycode).max(1);
    let code = |sym: u32| -> Option<u8> {
        map.keysyms.chunks(per).position(|syms| syms.contains(&sym)).and_then(|i| u8::try_from(usize::from(min) + i).ok())
    };
    let ctrl = code(0xffe3).ok_or_else(fail)?; // Control_L
    let v = code(0x0076).ok_or_else(fail)?; // v
    let mut events: Vec<(u8, u8)> = Vec::new();
    // Release Shift held from Shift+Return so the app sees plain Ctrl+V.
    for shift in [code(0xffe1), code(0xffe2)].into_iter().flatten() {
        events.push((KEY_RELEASE_EVENT, shift));
    }
    events.extend([(KEY_PRESS_EVENT, ctrl), (KEY_PRESS_EVENT, v), (KEY_RELEASE_EVENT, v), (KEY_RELEASE_EVENT, ctrl)]);
    for (kind, keycode) in events {
        conn.xtest_fake_input(kind, keycode, CURRENT_TIME, root, 0, 0, 0).map_err(|_| fail())?;
    }
    conn.flush().map_err(|_| fail())?;
    conn.get_input_focus().map_err(|_| fail())?.reply().map_err(|_| fail())?;
    Ok(())
}

pub fn work_area() -> Option<WorkArea> {
    let (conn, root) = connect()?;
    let pointer = conn.query_pointer(root).ok()?.reply().ok()?;
    let (px, py) = (i32::from(pointer.root_x), i32::from(pointer.root_y));
    let screen = &conn.setup().roots[0];
    let mut rect = (0i32, 0i32, i32::from(screen.width_in_pixels), i32::from(screen.height_in_pixels));
    if let Some(monitors) = conn.randr_get_monitors(root, true).ok().and_then(|c| c.reply().ok()) {
        let rects: Vec<_> = monitors
            .monitors
            .iter()
            .map(|m| (i32::from(m.x), i32::from(m.y), i32::from(m.width), i32::from(m.height)))
            .collect();
        if let Some(r) = rects.iter().find(|(x, y, w, h)| px >= *x && px < x + w && py >= *y && py < y + h).or(rects.first()) {
            rect = *r;
        }
    }
    // Keep clear of panels: intersect with _NET_WORKAREA of the first desktop.
    if let Some(area) = atom(&conn, "_NET_WORKAREA")
        .and_then(|a| conn.get_property(false, root, a, AtomEnum::CARDINAL, 0, 4).ok()?.reply().ok())
        .and_then(|r| r.value32().map(|v| v.collect::<Vec<u32>>()))
        .filter(|v| v.len() == 4)
    {
        let (ax, ay, aw, ah) = (area[0] as i32, area[1] as i32, area[2] as i32, area[3] as i32);
        let x0 = rect.0.max(ax);
        let y0 = rect.1.max(ay);
        let x1 = (rect.0 + rect.2).min(ax + aw);
        let y1 = (rect.1 + rect.3).min(ay + ah);
        if x1 > x0 && y1 > y0 {
            rect = (x0, y0, x1 - x0, y1 - y0);
        }
    }
    Some(WorkArea { x: rect.0 as f32, y: rect.1 as f32, width: rect.2 as f32, height: rect.3 as f32, scale: None })
}
