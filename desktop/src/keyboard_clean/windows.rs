//! Windows: a WH_KEYBOARD_LL hook on its own thread with a message loop
//! swallows every key, media and volume keys included.

use super::MonitorRect;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::thread::JoinHandle;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, HDC, HMONITOR};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage,
    UnhookWindowsHookEx, HHOOK, MSG, WH_KEYBOARD_LL, WM_QUIT,
};

/// Id of the hook thread, 0 when no block is active.
static HOOK_THREAD: AtomicU32 = AtomicU32::new(0);

pub struct Handle {
    thread: Option<JoinHandle<()>>,
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        // Swallow: the key never reaches any app or the shell.
        return LRESULT(1);
    }
    CallNextHookEx(HHOOK::default(), code, wparam, lparam)
}

pub fn start() -> Result<Handle, String> {
    if HOOK_THREAD.load(Ordering::SeqCst) != 0 {
        return Err("Keyboard is already blocked".into());
    }
    let (tx, rx) = mpsc::channel::<Result<u32, String>>();
    let thread = std::thread::Builder::new()
        .name("keyboard-clean-hook".into())
        .spawn(move || unsafe {
            let module = GetModuleHandleW(PCWSTR::null()).map(|m| HINSTANCE(m.0)).unwrap_or_default();
            let hook = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), module, 0) {
                Ok(h) => h,
                Err(e) => {
                    let _ = tx.send(Err(format!("Couldn't block the keyboard: {e}")));
                    return;
                }
            };
            let tid = GetCurrentThreadId();
            HOOK_THREAD.store(tid, Ordering::SeqCst);
            let _ = tx.send(Ok(tid));
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, HWND::default(), 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let _ = UnhookWindowsHookEx(hook);
            HOOK_THREAD.store(0, Ordering::SeqCst);
        })
        .map_err(|e| format!("Couldn't block the keyboard: {e}"))?;
    match rx.recv() {
        Ok(Ok(_)) => Ok(Handle { thread: Some(thread) }),
        Ok(Err(e)) => {
            let _ = thread.join();
            Err(e)
        }
        Err(_) => Err("Couldn't block the keyboard".into()),
    }
}

pub fn stop(mut h: Handle) {
    emergency_release();
    if let Some(t) = h.thread.take() {
        let _ = t.join();
    }
}

/// Ends the hook thread's message loop, which unhooks. Never blocks.
pub fn emergency_release() {
    let tid = HOOK_THREAD.load(Ordering::SeqCst);
    if tid != 0 {
        unsafe {
            let _ = PostThreadMessageW(tid, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
}

unsafe extern "system" fn monitor_proc(_: HMONITOR, _: HDC, rect: *mut RECT, data: LPARAM) -> BOOL {
    let list = &mut *(data.0 as *mut Vec<MonitorRect>);
    if let Some(r) = rect.as_ref() {
        list.push(MonitorRect { x: r.left, y: r.top, w: r.right - r.left, h: r.bottom - r.top });
    }
    BOOL(1)
}

pub fn monitors() -> Vec<MonitorRect> {
    let mut list: Vec<MonitorRect> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(HDC::default(), None, Some(monitor_proc), LPARAM(&mut list as *mut _ as isize));
    }
    list
}
