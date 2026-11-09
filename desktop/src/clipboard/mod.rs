mod item;
mod panel;
mod platform;
mod store;
mod watcher;

#[allow(unused_imports)]
pub use item::{ClipboardItem, Kind};
pub use store::{ClipboardStore, Limits};
pub use watcher::ClipboardWatcher;

use crate::feature::{Ctx, Feature, Shortcut};
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use panel::{Command, Panel};
use platform::WindowId;
use std::time::{Duration, Instant};

/// Steps after a paste is picked: the panel closes, then the previous window
/// gets focus back, then Ctrl+V goes to it.
enum Pending {
    Focus { window: Option<WindowId>, at: Instant },
    Keys { at: Instant },
}

/// Clipboard history: watcher, store, card-strip panel and paste.
/// Mirrors ClipboardHistory.swift.
pub struct ClipboardFeature {
    store: Option<ClipboardStore>,
    watcher: Option<ClipboardWatcher>,
    panel: Panel,
    previous: Option<WindowId>,
    pending: Option<Pending>,
}

impl ClipboardFeature {
    pub fn new() -> Self {
        Self { store: None, watcher: None, panel: Panel::default(), previous: None, pending: None }
    }

    fn paste(&mut self, id: uuid::Uuid, plain: bool, ctx: &mut Ctx) {
        let (Some(store), Some(watcher)) = (&mut self.store, &mut self.watcher) else { return };
        let Some(item) = store.items().iter().find(|i| i.id == id).cloned() else { return };
        if let Err(e) = write(watcher.clipboard(), store, &item, plain) {
            log::error!("clipboard write: {e}");
            ctx.hud.push("Couldn't write to the clipboard".into());
            return;
        }
        platform::mark_own_write();
        watcher.resync();
        if let Err(e) = store.touch(id) {
            log::error!("clipboard store: {e}");
        }
        self.panel.hide();
        self.pending = Some(Pending::Focus { window: self.previous.take(), at: Instant::now() + Duration::from_millis(40) });
    }

    fn run_pending(&mut self, ctx: &mut Ctx) {
        match self.pending {
            Some(Pending::Focus { window, at }) if Instant::now() >= at => {
                if let Some(w) = window {
                    platform::activate(w);
                }
                // Let the target app take key focus back before the keystroke lands.
                self.pending = Some(Pending::Keys { at: Instant::now() + Duration::from_millis(60) });
            }
            Some(Pending::Keys { at }) if Instant::now() >= at => {
                self.pending = None;
                if let Err(msg) = platform::send_paste() {
                    log::info!("paste not sent: {msg}");
                    ctx.hud.push(msg);
                }
            }
            Some(_) => ctx.egui.request_repaint_after(Duration::from_millis(10)),
            None => {}
        }
    }
}

fn write(clipboard: &mut arboard::Clipboard, store: &ClipboardStore, item: &ClipboardItem, plain: bool) -> anyhow::Result<()> {
    match item.kind {
        Kind::Files if !plain => clipboard.set().file_list(&item.files)?,
        Kind::RichText if !plain => {
            let text = item.text.clone().unwrap_or_default();
            match &item.html {
                Some(html) => clipboard.set().html(html.as_str(), Some(text.as_str()))?,
                None => clipboard.set_text(text)?,
            }
        }
        Kind::Image => {
            let name = item.image_file.as_deref().ok_or_else(|| anyhow::anyhow!("image file missing"))?;
            let img = image::open(store.image_path(name))?.to_rgba8();
            clipboard.set_image(arboard::ImageData {
                width: img.width() as usize,
                height: img.height() as usize,
                bytes: img.into_raw().into(),
            })?
        }
        _ => clipboard.set_text(item.plain_text())?,
    }
    Ok(())
}

impl Feature for ClipboardFeature {
    fn id(&self) -> &'static str {
        "clipboard"
    }
    fn title(&self) -> &'static str {
        "Clipboard history"
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        vec![Shortcut {
            id: "open",
            label: "Open clipboard history",
            default: HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::KeyV),
        }]
    }
    fn set_enabled(&mut self, on: bool, ctx: &mut Ctx) {
        if on && self.store.is_none() {
            match ClipboardStore::open(ctx.data_dir, Limits::default()) {
                Ok(s) => self.store = Some(s),
                Err(e) => log::error!("clipboard store: {e}"),
            }
        }
        self.watcher = if on {
            ClipboardWatcher::new().map_err(|e| log::error!("clipboard watcher: {e}")).ok()
        } else {
            None
        };
        if !on {
            self.panel.hide();
            self.pending = None;
        }
    }
    fn on_shortcut(&mut self, _id: &str, ctx: &mut Ctx) {
        if self.store.is_none() {
            ctx.hud.push("Clipboard history unavailable".into());
            return;
        }
        if self.panel.visible {
            self.panel.hide();
            return;
        }
        self.previous = platform::foreground_window();
        self.panel.show(platform::work_area(), ctx.egui);
    }
    fn update(&mut self, ctx: &mut Ctx) {
        if let (Some(w), Some(s)) = (&mut self.watcher, &mut self.store) {
            w.poll(s);
        }
        let command = match &mut self.store {
            Some(store) => self.panel.ui(ctx.egui, store),
            None => None,
        };
        match command {
            Some(Command::Paste(id, plain)) => self.paste(id, plain, ctx),
            Some(Command::Closed) => {
                if let Some(w) = self.previous.take() {
                    platform::activate(w);
                }
            }
            None => {}
        }
        self.run_pending(ctx);
    }
    fn shutdown(&mut self) {
        self.panel.hide();
    }
}
