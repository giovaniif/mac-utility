//! Win32 backend: monitors and top-level windows via EnumDisplayMonitors /
//! EnumWindows (DWM frame bounds, cloaked windows skipped), keystrokes via a
//! WH_KEYBOARD_LL hook on its own thread, and WDA_EXCLUDEFROMCAPTURE for the bar.

use super::super::ffmpeg;
use super::super::geom::Rect;
use super::super::keys::{vk_label, Stroke};
use std::path::Path;
use std::sync::mpsc::Sender;
use std::sync::Mutex;
use windows::core::{HSTRING, PCWSTR};
use windows::Win32::Foundation::{BOOL, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, HDC, HMONITOR};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, EnumWindows, FindWindowW, GetMessageW, GetWindowLongW, GetWindowTextLengthW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, PostThreadMessageW, SetWindowDisplayAffinity,
    SetWindowsHookExW, UnhookWindowsHookEx, GWL_EXSTYLE, KBDLLHOOKSTRUCT, MSG, WDA_EXCLUDEFROMCAPTURE,
    WH_KEYBOARD_LL, WM_KEYDOWN, WM_QUIT, WM_SYSKEYDOWN, WS_EX_TOOLWINDOW,
};

pub fn check_session() -> Result<(), String> {
    Ok(())
}

fn rect(r: &RECT) -> Rect {
    Rect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
}

unsafe extern "system" fn monitor_cb(_m: HMONITOR, _dc: HDC, r: *mut RECT, data: LPARAM) -> BOOL {
    let out = &mut *(data.0 as *mut Vec<Rect>);
    out.push(rect(&*r));
    true.into()
}

pub fn monitors() -> Vec<Rect> {
    let mut out: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(monitor_cb), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

unsafe extern "system" fn window_cb(hwnd: HWND, data: LPARAM) -> BOOL {
    let out = &mut *(data.0 as *mut Vec<Rect>);
    if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() || GetWindowTextLengthW(hwnd) == 0 {
        return true.into();
    }
    if (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0 {
        return true.into();
    }
    let mut pid = 0u32;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    if pid == GetCurrentProcessId() {
        return true.into();
    }
    let mut cloaked = 0u32;
    let _ = DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut _, 4);
    if cloaked != 0 {
        return true.into();
    }
    let mut r = RECT::default();
    if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut _, std::mem::size_of::<RECT>() as u32)
        .is_ok()
    {
        let r = rect(&r);
        if r.w > 0 && r.h > 0 {
            out.push(r);
        }
    }
    true.into()
}

/// Visible top-level windows of other apps, top to bottom (EnumWindows is z-ordered).
pub fn windows() -> Vec<Rect> {
    let mut out: Vec<Rect> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(window_cb), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

/// Keeps one of our windows out of every screen capture, gdigrab included.
pub fn exclude_from_capture(title: &str) -> bool {
    unsafe {
        let title = HSTRING::from(title);
        match FindWindowW(PCWSTR::null(), &title) {
            Ok(hwnd) if !hwnd.is_invalid() => SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE).is_ok(),
            _ => false,
        }
    }
}

pub fn display() -> String {
    String::new()
}

/// First DirectShow camera and microphone.
pub fn devices(ffmpeg_path: &Path) -> (Option<String>, Option<String>) {
    let out = ffmpeg::command(ffmpeg_path).args(ffmpeg::list_devices_args()).output();
    match out {
        Ok(o) => {
            let (v, a) = ffmpeg::parse_dshow_devices(&String::from_utf8_lossy(&o.stderr));
            (v.into_iter().next(), a.into_iter().next())
        }
        Err(e) => {
            log::warn!("listing devices: {e}");
            (None, None)
        }
    }
}

static HOOK_TX: Mutex<Option<Sender<Stroke>>> = Mutex::new(None);

fn down(vk: i32) -> bool {
    unsafe { GetAsyncKeyState(vk) as u16 & 0x8000 != 0 }
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && (wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN) {
        let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        if let Some(key) = vk_label(k.vkCode) {
            let s = Stroke { ctrl: down(0x11), alt: down(0x12), shift: down(0x10), meta: down(0x5B) || down(0x5C), key };
            if let Ok(g) = HOOK_TX.lock() {
                if let Some(tx) = g.as_ref() {
                    let _ = tx.send(s);
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// A low-level keyboard hook on a dedicated message-loop thread.
pub struct KeyHook {
    thread_id: u32,
    join: Option<std::thread::JoinHandle<()>>,
}

impl KeyHook {
    pub fn start(tx: Sender<Stroke>) -> Option<KeyHook> {
        *HOOK_TX.lock().ok()? = Some(tx);
        let (id_tx, id_rx) = std::sync::mpsc::channel();
        let join = std::thread::spawn(move || unsafe {
            let module = GetModuleHandleW(None).ok();
            let hook = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), HINSTANCE::from(module.unwrap_or_default()), 0) {
                Ok(h) => h,
                Err(e) => {
                    log::warn!("keyboard hook: {e}");
                    let _ = id_tx.send(None);
                    return;
                }
            };
            let _ = id_tx.send(Some(GetCurrentThreadId()));
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {}
            let _ = UnhookWindowsHookEx(hook);
        });
        let thread_id = id_rx.recv().ok().flatten()?;
        Some(KeyHook { thread_id, join: Some(join) })
    }
}

impl Drop for KeyHook {
    fn drop(&mut self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
        if let Ok(mut g) = HOOK_TX.lock() {
            *g = None;
        }
    }
}
