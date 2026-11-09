//! X11 through EWMH: _NET_CLIENT_LIST_STACKING to enumerate,
//! _NET_ACTIVE_WINDOW to focus, _NET_MOVERESIZE_WINDOW to place, RandR for
//! monitors, XGrabKeyboard for the modal grab. Wayland sessions can't move
//! other apps' windows, so `supported()` says no there.

use super::{GrabMode, Key, KeyEvent, Monitor, WinId, WindowInfo};
use crate::windows::geometry::Rect;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Mutex, OnceLock};
use x11rb::connection::Connection;
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ClientMessageEvent, ConnectionExt as _, EventMask, GrabMode as XGrabMode, GrabStatus, KeyPressEvent,
    Window, KEY_PRESS_EVENT, KEY_RELEASE_EVENT,
};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

struct Atoms {
    client_list: Atom,
    active: Atom,
    moveresize: Atom,
    pid: Atom,
    name: Atom,
    utf8: Atom,
    wtype: Atom,
    wtype_normal: Atom,
    state: Atom,
    hidden: Atom,
    fullscreen: Atom,
    max_v: Atom,
    max_h: Atom,
    extents: Atom,
    workarea: Atom,
}

struct X {
    conn: RustConnection,
    root: Window,
    atoms: Atoms,
}

static X: OnceLock<Option<Mutex<X>>> = OnceLock::new();

fn is_wayland() -> bool {
    std::env::var("XDG_SESSION_TYPE").map(|v| v.eq_ignore_ascii_case("wayland")).unwrap_or(false)
        || (std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("DISPLAY").is_none())
}

fn intern(conn: &RustConnection, name: &str) -> Atom {
    conn.intern_atom(false, name.as_bytes()).ok().and_then(|c| c.reply().ok()).map(|r| r.atom).unwrap_or(0)
}

fn x() -> Option<std::sync::MutexGuard<'static, X>> {
    X.get_or_init(|| {
        if is_wayland() {
            log::warn!("Wayland session: window management is off");
            return None;
        }
        let (conn, screen) = match x11rb::connect(None) {
            Ok(c) => c,
            Err(e) => {
                log::error!("X11 connect failed: {e}");
                return None;
            }
        };
        let root = conn.setup().roots[screen].root;
        let atoms = Atoms {
            client_list: intern(&conn, "_NET_CLIENT_LIST_STACKING"),
            active: intern(&conn, "_NET_ACTIVE_WINDOW"),
            moveresize: intern(&conn, "_NET_MOVERESIZE_WINDOW"),
            pid: intern(&conn, "_NET_WM_PID"),
            name: intern(&conn, "_NET_WM_NAME"),
            utf8: intern(&conn, "UTF8_STRING"),
            wtype: intern(&conn, "_NET_WM_WINDOW_TYPE"),
            wtype_normal: intern(&conn, "_NET_WM_WINDOW_TYPE_NORMAL"),
            state: intern(&conn, "_NET_WM_STATE"),
            hidden: intern(&conn, "_NET_WM_STATE_HIDDEN"),
            fullscreen: intern(&conn, "_NET_WM_STATE_FULLSCREEN"),
            max_v: intern(&conn, "_NET_WM_STATE_MAXIMIZED_VERT"),
            max_h: intern(&conn, "_NET_WM_STATE_MAXIMIZED_HORZ"),
            extents: intern(&conn, "_NET_FRAME_EXTENTS"),
            workarea: intern(&conn, "_NET_WORKAREA"),
        };
        Some(Mutex::new(X { conn, root, atoms }))
    })
    .as_ref()
    .and_then(|m| m.lock().ok())
}

pub fn supported() -> Result<(), String> {
    if is_wayland() {
        return Err("Window management needs an X11 session (Wayland doesn't allow it)".into());
    }
    x().map(|_| ()).ok_or_else(|| "Couldn't connect to the X server".into())
}

impl X {
    fn prop32(&self, win: Window, atom: Atom) -> Vec<u32> {
        self.conn
            .get_property(false, win, atom, AtomEnum::ANY, 0, 1024)
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.value32().map(|v| v.collect()))
            .unwrap_or_default()
    }

    fn prop_bytes(&self, win: Window, atom: Atom, kind: Atom) -> Vec<u8> {
        self.conn
            .get_property(false, win, atom, kind, 0, 4096)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| r.value)
            .unwrap_or_default()
    }

    fn title(&self, win: Window) -> String {
        let net = self.prop_bytes(win, self.atoms.name, self.atoms.utf8);
        if !net.is_empty() {
            return String::from_utf8_lossy(&net).into_owned();
        }
        String::from_utf8_lossy(&self.prop_bytes(win, AtomEnum::WM_NAME.into(), AtomEnum::STRING.into())).into_owned()
    }

    /// (instance, class) from WM_CLASS.
    fn class(&self, win: Window) -> (String, String) {
        let raw = self.prop_bytes(win, AtomEnum::WM_CLASS.into(), AtomEnum::STRING.into());
        let mut parts = raw.split(|&b| b == 0).map(|p| String::from_utf8_lossy(p).into_owned());
        let inst = parts.next().unwrap_or_default();
        let class = parts.next().unwrap_or_default();
        (inst, class)
    }

    /// Left, right, top, bottom decoration sizes.
    fn extents(&self, win: Window) -> (f64, f64, f64, f64) {
        let e = self.prop32(win, self.atoms.extents);
        if e.len() == 4 {
            (e[0] as f64, e[1] as f64, e[2] as f64, e[3] as f64)
        } else {
            (0.0, 0.0, 0.0, 0.0)
        }
    }

    /// Outer frame including decorations, in root coordinates.
    fn frame(&self, win: Window) -> Option<Rect> {
        let g = self.conn.get_geometry(win).ok()?.reply().ok()?;
        let t = self.conn.translate_coordinates(win, self.root, 0, 0).ok()?.reply().ok()?;
        let (l, r, top, b) = self.extents(win);
        Some(Rect::new(t.dst_x as f64 - l, t.dst_y as f64 - top, g.width as f64 + l + r, g.height as f64 + top + b))
    }

    fn client_message(&self, win: Window, kind: Atom, data: [u32; 5]) {
        let ev = ClientMessageEvent::new(32, win, kind, data);
        let _ = self.conn.send_event(
            false,
            self.root,
            EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
            ev,
        );
        let _ = self.conn.flush();
    }

    fn moveresize(&self, win: Window, frame: Rect, size: bool) {
        // Maximized windows ignore moves: drop the state first (remove = 0).
        if size {
            self.client_message(win, self.atoms.state, [0, self.atoms.max_v, self.atoms.max_h, 2, 0]);
        }
        let (l, r, t, b) = self.extents(win);
        // NorthWest gravity: x/y place the frame, width/height size the client.
        let mut flags: u32 = 1 | (1 << 8) | (1 << 9) | (2 << 12);
        if size {
            flags |= (1 << 10) | (1 << 11);
        }
        let w = (frame.w - l - r).max(1.0) as u32;
        let h = (frame.h - t - b).max(1.0) as u32;
        self.client_message(win, self.atoms.moveresize, [flags, frame.x as i32 as u32, frame.y as i32 as u32, w, h]);
    }
}

pub fn monitors() -> Vec<Monitor> {
    let Some(x) = x() else { return Vec::new() };
    let work = x.prop32(x.root, x.atoms.workarea);
    let work = (work.len() >= 4).then(|| Rect::new(work[0] as f64, work[1] as f64, work[2] as f64, work[3] as f64));
    let reply = x.conn.randr_get_monitors(x.root, true).ok().and_then(|c| c.reply().ok());
    let mut out: Vec<Monitor> = reply
        .map(|r| {
            r.monitors
                .iter()
                .map(|m| {
                    let frame = Rect::new(m.x as f64, m.y as f64, m.width as f64, m.height as f64);
                    let w = work.and_then(|w| w.intersection(&frame)).unwrap_or(frame);
                    Monitor { frame, work: w, primary: m.primary }
                })
                .collect()
        })
        .unwrap_or_default();
    if out.is_empty() {
        let s = &x.conn.setup().roots[0];
        let frame = Rect::new(0.0, 0.0, s.width_in_pixels as f64, s.height_in_pixels as f64);
        out.push(Monitor { frame, work: work.unwrap_or(frame), primary: true });
    }
    out
}

/// Managed top-level windows, front to back.
pub fn windows() -> Vec<WindowInfo> {
    let own = std::process::id();
    let mons: Vec<Rect> = monitors().into_iter().map(|m| m.frame).collect();
    let Some(x) = x() else { return Vec::new() };
    let list = x.prop32(x.root, x.atoms.client_list);
    let mut out = Vec::new();
    for &win in list.iter().rev() {
        let pid = x.prop32(win, x.atoms.pid).first().copied().unwrap_or(0);
        if pid == own {
            continue;
        }
        let Some(frame) = x.frame(win) else { continue };
        let types = x.prop32(win, x.atoms.wtype);
        let states = x.prop32(win, x.atoms.state);
        let (inst, class) = x.class(win);
        let normal = types.is_empty() || types.contains(&x.atoms.wtype_normal);
        let fullscreen = states.contains(&x.atoms.fullscreen) || mons.iter().any(|m| m.close_to(&frame));
        out.push(WindowInfo {
            id: win,
            app: if class.is_empty() { inst.clone() } else { class.clone() },
            app_name: if class.is_empty() { inst } else { class },
            title: x.title(win),
            frame,
            minimized: states.contains(&x.atoms.hidden),
            fullscreen,
            normal,
        });
    }
    out
}

pub fn foreground() -> Option<WinId> {
    let x = x()?;
    x.prop32(x.root, x.atoms.active).first().copied().filter(|&w| w != 0)
}

pub fn set_frame(id: WinId, frame: Rect) {
    if let Some(x) = x() {
        x.moveresize(id, frame, true);
    }
}

pub fn activate(id: WinId) {
    if let Some(x) = x() {
        // Source 2: a pager acting for the user.
        x.client_message(id, x.atoms.active, [2, 0, 0, 0, 0]);
    }
}

pub fn cursor() -> Option<(f64, f64)> {
    let x = x()?;
    let p = x.conn.query_pointer(x.root).ok()?.reply().ok()?;
    Some((p.root_x as f64, p.root_y as f64))
}

/// Runs a .desktop file's Exec line, without field codes.
pub fn launch(path: &std::path::Path) {
    let Ok(text) = std::fs::read_to_string(path) else { return };
    let Some(exec) = crate::windows::apps::desktop_exec(&text) else { return };
    if let Err(e) = std::process::Command::new("sh").arg("-c").arg(&exec).spawn() {
        log::error!("launch {exec}: {e}");
    }
}

pub fn take_dirty() -> bool {
    false
}

// Keyboard grab thread with its own connection.

static MODE: AtomicU8 = AtomicU8::new(0);
static RUNNING: AtomicBool = AtomicBool::new(false);
static QUEUE: Mutex<VecDeque<KeyEvent>> = Mutex::new(VecDeque::new());

fn keysym_key(sym: u32) -> Option<Key> {
    Some(match sym {
        0x61..=0x7a | 0x30..=0x39 | 0x2f | 0x5c | 0x2d | 0x2e | 0x2c => Key::Char(sym as u8 as char),
        0x41..=0x5a => Key::Char((sym as u8 + 32) as char),
        0x20 => Key::Space,
        0xff1b => Key::Escape,
        0xff09 | 0xfe20 => Key::Tab,
        0xff0d | 0xff8d => Key::Enter,
        0xff08 => Key::Backspace,
        0xff51 => Key::Left,
        0xff52 => Key::Up,
        0xff53 => Key::Right,
        0xff54 => Key::Down,
        0xffb0..=0xffb9 => Key::Char((b'0' + (sym - 0xffb0) as u8) as char),
        _ => return None,
    })
}

struct Keymap {
    min: u8,
    per: usize,
    syms: Vec<u32>,
}

impl Keymap {
    fn load(conn: &RustConnection) -> Option<Keymap> {
        let setup = conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let r = conn.get_keyboard_mapping(min, max - min + 1).ok()?.reply().ok()?;
        Some(Keymap { min, per: r.keysyms_per_keycode as usize, syms: r.keysyms })
    }
    fn sym(&self, code: u8) -> u32 {
        let i = (code.saturating_sub(self.min)) as usize * self.per;
        self.syms.get(i).copied().unwrap_or(0)
    }
    fn code(&self, sym: u32) -> Option<u8> {
        (0..self.syms.len() / self.per.max(1)).find(|&i| self.syms[i * self.per] == sym).map(|i| i as u8 + self.min)
    }
}

pub fn keys_start() {
    if RUNNING.swap(true, Ordering::Relaxed) || is_wayland() {
        return;
    }
    std::thread::Builder::new()
        .name("focus-keys".into())
        .spawn(|| {
            let Ok((conn, screen)) = x11rb::connect(None) else {
                RUNNING.store(false, Ordering::Relaxed);
                return;
            };
            let root = conn.setup().roots[screen].root;
            let Some(map) = Keymap::load(&conn) else {
                RUNNING.store(false, Ordering::Relaxed);
                return;
            };
            let mut grabbed = false;
            while RUNNING.load(Ordering::Relaxed) {
                let want = MODE.load(Ordering::Relaxed) == 1;
                if want && !grabbed {
                    grabbed = conn
                        .grab_keyboard(false, root, x11rb::CURRENT_TIME, XGrabMode::ASYNC, XGrabMode::ASYNC)
                        .ok()
                        .and_then(|c| c.reply().ok())
                        .is_some_and(|r| r.status == GrabStatus::SUCCESS);
                } else if !want && grabbed {
                    let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
                    let _ = conn.flush();
                    grabbed = false;
                }
                let mut idle = true;
                while let Ok(Some(ev)) = conn.poll_for_event() {
                    idle = false;
                    if let Event::KeyPress(e) = ev {
                        let state = u16::from(e.state);
                        if let Some(key) = keysym_key(map.sym(e.detail)) {
                            let ev = KeyEvent { key, shift: state & 1 != 0, ctrl: state & 4 != 0, alt: state & 8 != 0 };
                            if let Ok(mut q) = QUEUE.lock() {
                                q.push_back(ev);
                            }
                        }
                    }
                }
                if idle {
                    std::thread::sleep(std::time::Duration::from_millis(8));
                }
            }
            if grabbed {
                let _ = conn.ungrab_keyboard(x11rb::CURRENT_TIME);
                let _ = conn.flush();
            }
        })
        .ok();
}

pub fn keys_stop() {
    MODE.store(0, Ordering::Relaxed);
    RUNNING.store(false, Ordering::Relaxed);
    if let Ok(mut q) = QUEUE.lock() {
        q.clear();
    }
}

pub fn keys_set_mode(mode: GrabMode) {
    let v = if mode == GrabMode::Grab { 1 } else { 0 };
    if MODE.swap(v, Ordering::Relaxed) != v && v == 1 {
        if let Ok(mut q) = QUEUE.lock() {
            q.clear();
        }
    }
}

pub fn keys_poll() -> Vec<KeyEvent> {
    QUEUE.lock().map(|mut q| q.drain(..).collect()).unwrap_or_default()
}

/// Our own passive grab would catch an XTest keystroke, so send the key
/// event straight to the focused window. Apps that ignore synthetic events
/// (xterm by default) won't see it.
pub fn pass_through(key: char, ctrl: bool, shift: bool, alt: bool) {
    let Some(x) = x() else { return };
    let Some(map) = Keymap::load(&x.conn) else { return };
    let Some(code) = map.code(key as u32) else { return };
    let Some(focus) = x.conn.get_input_focus().ok().and_then(|c| c.reply().ok()).map(|r| r.focus) else { return };
    let mut state: u16 = 0;
    if shift {
        state |= 1;
    }
    if ctrl {
        state |= 4;
    }
    if alt {
        state |= 8;
    }
    for kind in [KEY_PRESS_EVENT, KEY_RELEASE_EVENT] {
        let ev = KeyPressEvent {
            response_type: kind,
            detail: code,
            sequence: 0,
            time: x11rb::CURRENT_TIME,
            root: x.root,
            event: focus,
            child: x11rb::NONE,
            root_x: 0,
            root_y: 0,
            event_x: 0,
            event_y: 0,
            state: state.into(),
            same_screen: true,
        };
        let _ = x.conn.send_event(true, focus, EventMask::KEY_PRESS | EventMask::KEY_RELEASE, ev);
    }
    let _ = x.conn.flush();
}
