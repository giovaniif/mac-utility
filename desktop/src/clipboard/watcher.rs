use super::item::{is_excluded_app, now, ClipboardItem, Kind};
use super::platform::{self, ChangeListener};
use super::store::ClipboardStore;
use arboard::Clipboard;
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Records clipboard changes. Windows wakes it with WM_CLIPBOARDUPDATE;
/// elsewhere it compares fingerprints with the last seen content each poll.
/// Mirrors ClipboardWatcher.swift.
pub struct ClipboardWatcher {
    clipboard: Clipboard,
    listener: ChangeListener,
    last: Option<String>,
}

impl ClipboardWatcher {
    pub fn new() -> anyhow::Result<Self> {
        let mut w = Self { clipboard: Clipboard::new()?, listener: ChangeListener::new(), last: None };
        // Don't record whatever was on the clipboard before launch.
        w.resync();
        Ok(w)
    }

    pub fn clipboard(&mut self) -> &mut Clipboard {
        &mut self.clipboard
    }

    /// Treats the current content as already seen. Called after our own writes.
    pub fn resync(&mut self) {
        self.listener.changed();
        self.last = self.peek().map(|(fp, _)| fp);
    }

    /// Records the clipboard if it changed since the last poll.
    pub fn poll(&mut self, store: &mut ClipboardStore) {
        if !self.listener.changed() {
            return;
        }
        let Some((fingerprint, content)) = self.peek() else { return };
        if self.last.as_deref() == Some(fingerprint.as_str()) {
            return;
        }
        self.last = Some(fingerprint.clone());
        let info = platform::clipboard_info();
        if info.skip || info.source_app.as_deref().is_some_and(is_excluded_app) {
            return;
        }
        let source = info.source_app;
        let item = match content {
            Content::Text { text, html } => ClipboardItem::text(text, html, source),
            Content::Files(files) => ClipboardItem::files(files, source),
            Content::Image { width, height, rgba } => match image_item(store, fingerprint, width, height, rgba, source) {
                Some(item) => item,
                None => return,
            },
        };
        if let Err(e) = store.add(item) {
            log::error!("clipboard write failed: {e}");
        }
    }

    fn peek(&mut self) -> Option<(String, Content)> {
        if let Ok(files) = self.clipboard.get().file_list() {
            let files: Vec<String> = files.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            if !files.is_empty() {
                return Some((format!("files:{}", files.join("\n")), Content::Files(files)));
            }
        }
        if let Ok(img) = self.clipboard.get_image() {
            let hash = hex(&Sha256::digest(&img.bytes));
            let content = Content::Image {
                width: img.width as u32,
                height: img.height as u32,
                rgba: img.bytes.into_owned(),
            };
            return Some((format!("image:{hash}"), content));
        }
        let text = self.clipboard.get_text().ok().filter(|t| !t.is_empty())?;
        let html = self.clipboard.get().html().ok().filter(|h| !h.is_empty());
        Some((format!("text:{text}"), Content::Text { text, html }))
    }
}

enum Content {
    Text { text: String, html: Option<String> },
    Files(Vec<String>),
    Image { width: u32, height: u32, rgba: Vec<u8> },
}

fn image_item(
    store: &ClipboardStore,
    fingerprint: String,
    w: u32,
    h: u32,
    rgba: Vec<u8>,
    source_app: Option<String>,
) -> Option<ClipboardItem> {
    let img = image::RgbaImage::from_raw(w, h, rgba)?;
    let id = Uuid::new_v4();
    let image_name = format!("{id}.png");
    let thumb_name = format!("{id}-thumb.png");
    let scale = (360.0 / w.max(h) as f32).min(1.0);
    let thumb = image::imageops::thumbnail(&img, ((w as f32 * scale) as u32).max(1), ((h as f32 * scale) as u32).max(1));
    if let Err(e) = img.save(store.image_path(&image_name)).and_then(|_| thumb.save(store.image_path(&thumb_name))) {
        log::error!("image write failed: {e}");
        return None;
    }
    Some(ClipboardItem {
        id,
        kind: Kind::Image,
        text: None,
        html: None,
        image_file: Some(image_name),
        thumbnail_file: Some(thumb_name),
        files: Vec::new(),
        source_app,
        date: now(),
        pinned: false,
        fingerprint,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
