use super::item::{now, ClipboardItem, Kind};
use super::store::ClipboardStore;
use arboard::Clipboard;
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Polls the system clipboard. Neither Windows nor Linux gives arboard a
/// change counter, so it compares fingerprints with the last seen content.
/// Mirrors ClipboardWatcher.swift.
pub struct ClipboardWatcher {
    clipboard: Clipboard,
    last: Option<String>,
}

impl ClipboardWatcher {
    pub fn new() -> anyhow::Result<Self> {
        let mut w = Self { clipboard: Clipboard::new()?, last: None };
        // Don't record whatever was on the clipboard before launch.
        w.last = w.peek().map(|(fp, _)| fp);
        Ok(w)
    }

    /// Records the clipboard if it changed since the last poll.
    pub fn poll(&mut self, store: &mut ClipboardStore) {
        let Some((fingerprint, content)) = self.peek() else { return };
        if self.last.as_deref() == Some(fingerprint.as_str()) {
            return;
        }
        self.last = Some(fingerprint.clone());
        let item = match content {
            Content::Text(text) => ClipboardItem::text(text, None, None),
            Content::Image { width, height, rgba } => {
                match image_item(store, fingerprint, width, height, rgba) {
                    Some(item) => item,
                    None => return,
                }
            }
        };
        if let Err(e) = store.add(item) {
            log::error!("clipboard write failed: {e}");
        }
    }

    fn peek(&mut self) -> Option<(String, Content)> {
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
        Some((format!("text:{text}"), Content::Text(text)))
    }
}

enum Content {
    Text(String),
    Image { width: u32, height: u32, rgba: Vec<u8> },
}

fn image_item(store: &ClipboardStore, fingerprint: String, w: u32, h: u32, rgba: Vec<u8>) -> Option<ClipboardItem> {
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
        source_app: None,
        date: now(),
        pinned: false,
        fingerprint,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
