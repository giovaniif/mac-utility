mod item;
mod store;
mod watcher;

#[allow(unused_imports)]
pub use item::{ClipboardItem, Kind};
pub use store::{ClipboardStore, Limits};
pub use watcher::ClipboardWatcher;

use crate::feature::{Ctx, Feature, Shortcut};
use global_hotkey::hotkey::{Code, HotKey, Modifiers};

/// Clipboard history. The card-strip panel is still to come.
pub struct ClipboardFeature {
    store: Option<ClipboardStore>,
    watcher: Option<ClipboardWatcher>,
}

impl ClipboardFeature {
    pub fn new() -> Self {
        Self { store: None, watcher: None }
    }
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
        self.watcher = if on { ClipboardWatcher::new().ok() } else { None };
    }
    fn on_shortcut(&mut self, _id: &str, ctx: &mut Ctx) {
        let n = self.store.as_ref().map_or(0, |s| s.items().len());
        ctx.hud.push(format!("{n} clipboard items"));
    }
    fn update(&mut self, _ctx: &mut Ctx) {
        if let (Some(w), Some(s)) = (&mut self.watcher, &mut self.store) {
            w.poll(s);
        }
    }
}
