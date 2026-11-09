//! Win32: clipboard listener window, skip formats, owner process name,
//! foreground restore and SendInput.

use super::{ClipInfo, WindowId, WorkArea};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, GlobalFree, HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, GetClipboardData, GetClipboardOwner, GetClipboardSequenceNumber,
    IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT, VK_V,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetCursorPos, GetForegroundWindow, GetMessageW,
    GetWindowThreadProcessId, IsIconic, IsWindow, RegisterClassW, SetForegroundWindow, ShowWindow, HWND_MESSAGE, MSG,
    SW_RESTORE, WINDOW_EX_STYLE, WINDOW_STYLE, WM_CLIPBOARDUPDATE, WNDCLASSW,
};

const MARKER: PCWSTR = w!("MacUtilityPaste");

static DIRTY: AtomicBool = AtomicBool::new(true);

/// WM_CLIPBOARDUPDATE on a message-only window in its own thread. Falls back
/// to GetClipboardSequenceNumber if the window can't be made.
pub struct ChangeListener {
    listening: bool,
    sequence: u32,
}

impl ChangeListener {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || listen(tx));
        let listening = rx.recv().unwrap_or(false);
        if !listening {
            log::warn!("clipboard listener unavailable, polling the sequence number");
        }
        Self { listening, sequence: unsafe { GetClipboardSequenceNumber() } }
    }

    pub fn changed(&mut self) -> bool {
        if self.listening {
            return DIRTY.swap(false, Ordering::AcqRel);
        }
        let now = unsafe { GetClipboardSequenceNumber() };
        std::mem::replace(&mut self.sequence, now) != now
    }
}

fn listen(ready: mpsc::Sender<bool>) {
    unsafe {
        let Ok(module) = GetModuleHandleW(None) else {
            let _ = ready.send(false);
            return;
        };
        let class = w!("MacUtilityClipboardListener");
        let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: module.into(), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            w!(""),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            None,
            module,
            None,
        );
        let Ok(hwnd) = hwnd else {
            let _ = ready.send(false);
            return;
        };
        if AddClipboardFormatListener(hwnd).is_err() {
            let _ = ready.send(false);
            return;
        }
        let _ = ready.send(true);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            DispatchMessageW(&msg);
        }
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_CLIPBOARDUPDATE {
        DIRTY.store(true, Ordering::Release);
        return LRESULT(0);
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

fn format(name: PCWSTR) -> u32 {
    unsafe { RegisterClipboardFormatW(name) }
}

fn available(format: u32) -> bool {
    format != 0 && unsafe { IsClipboardFormatAvailable(format).is_ok() }
}

pub fn clipboard_info() -> ClipInfo {
    let hidden = available(format(MARKER))
        || available(format(w!("ExcludeClipboardContentFromMonitorProcessing")))
        || available(format(w!("Clipboard Viewer Ignore")));
    let history = format(w!("CanIncludeInClipboardHistory"));
    let skip = hidden || (available(history) && read_dword(history) == Some(0));
    let owner = unsafe { GetClipboardOwner() }.ok().filter(|h| !h.is_invalid());
    let source_app = owner.and_then(exe_of).or_else(|| exe_of(unsafe { GetForegroundWindow() }));
    ClipInfo { skip, source_app }
}

fn read_dword(format: u32) -> Option<u32> {
    unsafe {
        OpenClipboard(None).ok()?;
        let value = GetClipboardData(format).ok().and_then(|h| {
            let global = HGLOBAL(h.0);
            if GlobalSize(global) < 4 {
                return None;
            }
            let ptr = GlobalLock(global) as *const u32;
            if ptr.is_null() {
                return None;
            }
            let v = ptr.read_unaligned();
            let _ = GlobalUnlock(global);
            Some(v)
        });
        let _ = CloseClipboard();
        value
    }
}

fn exe_of(hwnd: HWND) -> Option<String> {
    if hwnd.is_invalid() {
        return None;
    }
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(process);
        ok.ok()?;
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        path.rsplit('\\').next().map(str::to_string)
    }
}

/// Adds an empty marker format to what's on the clipboard so the watcher
/// (and the macOS-style marker check) skips our own paste.
pub fn mark_own_write() {
    unsafe {
        if OpenClipboard(None).is_err() {
            return;
        }
        if let Ok(global) = GlobalAlloc(GMEM_MOVEABLE, 1) {
            if SetClipboardData(format(MARKER), HANDLE(global.0)).is_err() {
                let _ = GlobalFree(global);
            }
        }
        let _ = CloseClipboard();
    }
}

pub fn foreground_window() -> Option<WindowId> {
    let hwnd = unsafe { GetForegroundWindow() };
    (!hwnd.is_invalid()).then_some(hwnd.0 as usize as WindowId)
}

pub fn activate(window: WindowId) {
    let hwnd = HWND(window as usize as *mut _);
    unsafe {
        if !IsWindow(hwnd).as_bool() {
            return;
        }
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        if !SetForegroundWindow(hwnd).as_bool() {
            // A tapped Alt lifts the foreground lock, then retry.
            send(&[key(VK_MENU, false), key(VK_MENU, true)]);
            let _ = SetForegroundWindow(hwnd);
        }
    }
}

fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn send(inputs: &[INPUT]) -> u32 {
    unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) }
}

pub fn send_paste() -> Result<(), String> {
    let mut inputs = Vec::new();
    // Release modifiers still held from Shift+Return so the app sees plain Ctrl+V.
    for vk in [VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_MENU, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN] {
        if unsafe { GetAsyncKeyState(i32::from(vk.0)) } < 0 {
            inputs.push(key(vk, true));
        }
    }
    inputs.extend([key(VK_CONTROL, false), key(VK_V, false), key(VK_V, true), key(VK_CONTROL, true)]);
    if send(&inputs) as usize == inputs.len() {
        Ok(())
    } else {
        Err("Copied. Press Ctrl+V to paste".into())
    }
}

pub fn work_area() -> Option<WorkArea> {
    unsafe {
        let mut pt = POINT::default();
        GetCursorPos(&mut pt).ok()?;
        let monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return None;
        }
        let (mut dx, mut dy) = (96u32, 96u32);
        let scale = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dx, &mut dy).ok().map(|_| dx as f32 / 96.0);
        let r = info.rcWork;
        Some(WorkArea {
            x: r.left as f32,
            y: r.top as f32,
            width: (r.right - r.left) as f32,
            height: (r.bottom - r.top) as f32,
            scale,
        })
    }
}
