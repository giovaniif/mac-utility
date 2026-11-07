//! Win32: EnumWindows/SetWindowPos for windows, EnumDisplayMonitors for work
//! areas, a WH_KEYBOARD_LL hook for the modal grab and SetWinEventHook to
//! notice new windows and focus changes without waiting for the next poll.

use super::{GrabMode, Key, KeyEvent, Monitor, WinId, WindowInfo};
use crate::windows::geometry::Rect;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};
use std::sync::Mutex;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{BOOL, CloseHandle, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    AttachThreadInput, GetCurrentProcessId, GetCurrentThreadId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, MapVirtualKeyW, MAPVK_VK_TO_VSC, VK_CONTROL, VK_MENU, VK_SHIFT};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::*;

pub fn supported() -> Result<(), String> {
    Ok(())
}

fn hwnd(id: WinId) -> HWND {
    HWND(id as usize as *mut core::ffi::c_void)
}

fn rect(r: RECT) -> Rect {
    Rect::new(r.left as f64, r.top as f64, (r.right - r.left) as f64, (r.bottom - r.top) as f64)
}

pub fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn cb(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let out = &mut *(data.0 as *mut Vec<Monitor>);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if GetMonitorInfoW(m, &mut info).as_bool() {
            out.push(Monitor { frame: rect(info.rcMonitor), work: rect(info.rcWork), primary: info.dwFlags & 1 != 0 });
        }
        BOOL(1)
    }
    let mut out: Vec<Monitor> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(HDC::default(), None, Some(cb), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

fn text(h: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn class(h: HWND) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

fn exe(pid: u32) -> String {
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return String::new() };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(h);
        if ok {
            String::from_utf16_lossy(&buf[..len as usize])
        } else {
            String::new()
        }
    }
}

fn cloaked(h: HWND) -> bool {
    let mut v: u32 = 0;
    unsafe {
        DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut v as *mut u32 as *mut _, std::mem::size_of::<u32>() as u32).is_ok() && v != 0
    }
}

/// The frame as seen on screen: GetWindowRect includes invisible resize
/// borders on Windows 10 and later; the DWM extended bounds don't.
fn visible_frame(h: HWND) -> Option<Rect> {
    let mut r = RECT::default();
    unsafe {
        if DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut RECT as *mut _, std::mem::size_of::<RECT>() as u32).is_ok() {
            return Some(rect(r));
        }
        GetWindowRect(h, &mut r).ok()?;
    }
    Some(rect(r))
}

fn outer_frame(h: HWND) -> Option<Rect> {
    let mut r = RECT::default();
    unsafe { GetWindowRect(h, &mut r).ok()? };
    Some(rect(r))
}

const SKIP_CLASSES: &[&str] = &["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow"];

fn info(h: HWND, own: u32, monitors: &[Monitor]) -> Option<WindowInfo> {
    unsafe {
        if !IsWindowVisible(h).as_bool() || cloaked(h) {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(h, Some(&mut pid));
        if pid == own {
            return None;
        }
        let class = class(h);
        if SKIP_CLASSES.contains(&class.as_str()) {
            return None;
        }
        let title = text(h);
        let style = GetWindowLongW(h, GWL_STYLE) as u32;
        let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
        let owned = GetWindow(h, GW_OWNER).map(|o| !o.0.is_null()).unwrap_or(false);
        let tool = ex & WS_EX_TOOLWINDOW.0 != 0 || ex & WS_EX_NOACTIVATE.0 != 0;
        let resizable = style & WS_THICKFRAME.0 != 0 && style & WS_CAPTION.0 == WS_CAPTION.0;
        if tool && title.is_empty() {
            return None;
        }
        let frame = visible_frame(h)?;
        let minimized = IsIconic(h).as_bool();
        let fullscreen = style & WS_CAPTION.0 == 0 && monitors.iter().any(|m| m.frame.close_to(&frame));
        let path = exe(pid);
        let app_name = std::path::Path::new(&path)
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| class.clone());
        Some(WindowInfo {
            id: h.0 as usize as u32,
            app: if path.is_empty() { class } else { path.to_lowercase() },
            app_name,
            title,
            frame,
            minimized,
            fullscreen,
            normal: resizable && !owned && !tool,
        })
    }
}

/// Visible top-level windows, front to back.
pub fn windows() -> Vec<WindowInfo> {
    unsafe extern "system" fn cb(h: HWND, data: LPARAM) -> BOOL {
        let out = &mut *(data.0 as *mut Vec<HWND>);
        out.push(h);
        BOOL(1)
    }
    let mut handles: Vec<HWND> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut handles as *mut _ as isize));
    }
    let own = unsafe { GetCurrentProcessId() };
    let mons = monitors();
    handles.into_iter().filter_map(|h| info(h, own, &mons)).collect()
}

pub fn foreground() -> Option<WinId> {
    let h = unsafe { GetForegroundWindow() };
    (!h.0.is_null()).then_some(h.0 as usize as u32)
}

/// Moves and resizes so the visible frame lands on `frame`.
pub fn set_frame(id: WinId, frame: Rect) {
    let h = hwnd(id);
    unsafe {
        if IsZoomed(h).as_bool() || IsIconic(h).as_bool() {
            let _ = ShowWindow(h, SW_RESTORE);
        }
        // Outer rect = visible rect plus the invisible borders.
        let (outer, vis) = (outer_frame(h), visible_frame(h));
        let (l, t, r, b) = match (outer, vis) {
            (Some(o), Some(v)) => (v.x - o.x, v.y - o.y, o.max_x() - v.max_x(), o.max_y() - v.max_y()),
            _ => (0.0, 0.0, 0.0, 0.0),
        };
        let _ = SetWindowPos(
            h,
            HWND::default(),
            (frame.x - l).round() as i32,
            (frame.y - t).round() as i32,
            (frame.w + l + r).round() as i32,
            (frame.h + t + b).round() as i32,
            SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }
}

/// Raises and focuses a window. Windows only lets the foreground process
/// move focus, so borrow the foreground thread's input state for the call.
pub fn activate(id: WinId) {
    let h = hwnd(id);
    unsafe {
        if IsIconic(h).as_bool() {
            let _ = ShowWindow(h, SW_RESTORE);
        }
        if SetForegroundWindow(h).as_bool() {
            return;
        }
        let fg = GetForegroundWindow();
        let fg_thread = GetWindowThreadProcessId(fg, None);
        let me = GetCurrentThreadId();
        let attached = fg_thread != 0 && fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool();
        let _ = BringWindowToTop(h);
        let _ = SetForegroundWindow(h);
        if attached {
            let _ = AttachThreadInput(me, fg_thread, false);
        }
    }
}

pub fn cursor() -> Option<(f64, f64)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p).ok()? };
    Some((p.x as f64, p.y as f64))
}

/// Opens a Start Menu shortcut or executable.
pub fn launch(path: &std::path::Path) {
    let wide: Vec<u16> = path.as_os_str().to_string_lossy().encode_utf16().chain(Some(0)).collect();
    let verb: Vec<u16> = "open".encode_utf16().chain(Some(0)).collect();
    unsafe {
        ShellExecuteW(HWND::default(), PCWSTR(verb.as_ptr()), PCWSTR(wide.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
    }
}

// Hook thread: keyboard grab and window events.

static MODE: AtomicU8 = AtomicU8::new(0);
static DIRTY: AtomicBool = AtomicBool::new(true);
static THREAD: AtomicU32 = AtomicU32::new(0);
static QUEUE: Mutex<VecDeque<KeyEvent>> = Mutex::new(VecDeque::new());
/// Marks keystrokes we post ourselves so the hook lets them through.
const OURS: usize = 0x4D55_5449;

pub fn take_dirty() -> bool {
    DIRTY.swap(false, Ordering::Relaxed)
}

fn down(vk: u16) -> bool {
    unsafe { (GetAsyncKeyState(vk as i32) as u16 & 0x8000) != 0 }
}

fn translate(vk: u32) -> Option<Key> {
    Some(match vk {
        0x41..=0x5A => Key::Char((vk as u8 + 32) as char),
        0x30..=0x39 => Key::Char(vk as u8 as char),
        0x60..=0x69 => Key::Char((b'0' + (vk - 0x60) as u8) as char),
        0x20 => Key::Space,
        0x1B => Key::Escape,
        0x09 => Key::Tab,
        0x0D => Key::Enter,
        0x08 => Key::Backspace,
        0x25 => Key::Left,
        0x26 => Key::Up,
        0x27 => Key::Right,
        0x28 => Key::Down,
        0xDC | 0xE2 => Key::Char('\\'),
        0xBF => Key::Char('/'),
        0xBD => Key::Char('-'),
        0xBE => Key::Char('.'),
        0xBC => Key::Char(','),
        _ => return None,
    })
}

fn is_modifier(vk: u32) -> bool {
    matches!(vk, 0x10 | 0x11 | 0x12 | 0x14 | 0x5B | 0x5C | 0xA0..=0xA5)
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 && MODE.load(Ordering::Relaxed) != 0 {
        let kb = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        if kb.dwExtraInfo != OURS && !is_modifier(kb.vkCode) {
            let msg = wparam.0 as u32;
            if msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN {
                if let Some(key) = translate(kb.vkCode) {
                    let ev = KeyEvent { key, shift: down(VK_SHIFT.0), ctrl: down(VK_CONTROL.0), alt: down(VK_MENU.0) };
                    if let Ok(mut q) = QUEUE.lock() {
                        q.push_back(ev);
                    }
                }
            }
            // Swallow presses and releases alike while grabbed.
            return LRESULT(1);
        }
    }
    CallNextHookEx(HHOOK::default(), code, wparam, lparam)
}

unsafe extern "system" fn win_event(_: HWINEVENTHOOK, _: u32, _: HWND, id_object: i32, _: i32, _: u32, _: u32) {
    if id_object == OBJID_WINDOW.0 {
        DIRTY.store(true, Ordering::Relaxed);
    }
}

pub fn keys_start() {
    if THREAD.load(Ordering::Relaxed) != 0 {
        return;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("focus-hooks".into())
        .spawn(move || unsafe {
            let _ = tx.send(GetCurrentThreadId());
            let module = GetModuleHandleW(PCWSTR::null()).unwrap_or_default();
            let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), module, 0);
            if let Err(e) = &hook {
                log::error!("keyboard hook failed: {e}");
            }
            // Shown/hidden/destroyed, foreground, minimize, move/resize end.
            let events = [
                SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_HIDE, None, Some(win_event), 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS),
                SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, None, Some(win_event), 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS),
                SetWinEventHook(EVENT_SYSTEM_MOVESIZEEND, EVENT_SYSTEM_MINIMIZEEND, None, Some(win_event), 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS),
            ];
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, HWND::default(), 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            for e in events {
                let _ = UnhookWinEvent(e);
            }
            if let Ok(h) = hook {
                let _ = UnhookWindowsHookEx(h);
            }
        })
        .ok();
    if let Ok(id) = rx.recv() {
        THREAD.store(id, Ordering::Relaxed);
    }
}

pub fn keys_stop() {
    MODE.store(0, Ordering::Relaxed);
    let id = THREAD.swap(0, Ordering::Relaxed);
    if id != 0 {
        unsafe {
            let _ = PostThreadMessageW(id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
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

/// The leader's own hotkey would catch a synthesized keystroke, so post the
/// key messages straight to the focused control instead (tmux in a
/// terminal, Ctrl+B in an editor). Modifier state comes from the keyboard,
/// which still has Ctrl down.
pub fn pass_through(key: char, _ctrl: bool, _shift: bool, _alt: bool) {
    unsafe {
        let fg = GetForegroundWindow();
        if fg.0.is_null() {
            return;
        }
        let thread = GetWindowThreadProcessId(fg, None);
        let mut gui = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        let target = if GetGUIThreadInfo(thread, &mut gui).is_ok() && !gui.hwndFocus.0.is_null() { gui.hwndFocus } else { fg };
        let vk = key.to_ascii_uppercase() as u32;
        let scan = MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        let down_l = 1 | (scan << 16);
        let up_l = down_l | (1 << 30) | (1 << 31);
        let _ = PostMessageW(target, WM_KEYDOWN, WPARAM(vk as usize), LPARAM(down_l as isize));
        let _ = PostMessageW(target, WM_KEYUP, WPARAM(vk as usize), LPARAM(up_l as isize));
    }
}

