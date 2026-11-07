//! Window thumbnails for the switcher and shelf, and a still of the screen
//! for the set-switch fade. xcap on Windows and Linux; nothing elsewhere.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

pub struct Shot {
    pub id: u32,
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
}

pub struct Capturer {
    tx: Sender<Shot>,
    rx: Receiver<Shot>,
    busy: Arc<AtomicBool>,
}

impl Capturer {
    pub fn new() -> Self {
        let (tx, rx) = channel();
        Self { tx, rx, busy: Arc::new(AtomicBool::new(false)) }
    }

    /// Captures these windows in the background, unless a run is still going.
    pub fn request(&self, ids: Vec<u32>) {
        if ids.is_empty() || self.busy.swap(true, Ordering::AcqRel) {
            return;
        }
        let (tx, busy) = (self.tx.clone(), self.busy.clone());
        let spawned = std::thread::Builder::new().name("focus-thumbs".into()).spawn(move || {
            imp::windows(&ids, &tx);
            busy.store(false, Ordering::Release);
        });
        if spawned.is_err() {
            self.busy.store(false, Ordering::Release);
        }
    }

    pub fn poll(&self) -> Vec<Shot> {
        self.rx.try_iter().collect()
    }
}

/// A still of the primary display, at full size.
pub fn primary_screen() -> Option<Shot> {
    imp::screen()
}

#[cfg(any(windows, target_os = "linux"))]
mod imp {
    use super::Shot;
    use std::sync::mpsc::Sender;

    fn shot(id: u32, img: image::RgbaImage, max_w: u32) -> Shot {
        let img = if img.width() > max_w {
            let h = (img.height() as u64 * max_w as u64 / img.width().max(1) as u64).max(1) as u32;
            image::imageops::thumbnail(&img, max_w, h)
        } else {
            img
        };
        Shot { id, w: img.width(), h: img.height(), rgba: img.into_raw() }
    }

    pub fn windows(ids: &[u32], tx: &Sender<Shot>) {
        let Ok(all) = xcap::Window::all() else { return };
        for w in all {
            let Ok(id) = w.id() else { continue };
            if !ids.contains(&id) {
                continue;
            }
            match w.capture_image() {
                Ok(img) => {
                    if tx.send(shot(id, img, 480)).is_err() {
                        return;
                    }
                }
                Err(e) => log::debug!("thumbnail {id}: {e}"),
            }
        }
    }

    pub fn screen() -> Option<Shot> {
        let monitors = xcap::Monitor::all().ok()?;
        let m = monitors.iter().find(|m| m.is_primary().unwrap_or(false)).or(monitors.first())?;
        let img = m.capture_image().ok()?;
        Some(shot(0, img, u32::MAX))
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod imp {
    use super::Shot;
    use std::sync::mpsc::Sender;

    pub fn windows(_ids: &[u32], _tx: &Sender<Shot>) {}

    pub fn screen() -> Option<Shot> {
        None
    }
}
