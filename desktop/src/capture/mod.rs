//! Screenshots: area/window selection, full screen under the pointer, a
//! quick-access thumbnail stack and an annotation editor. Captures stay in a
//! cache folder until saved.

pub mod annotate;
mod editor;
pub mod grab;
mod quick;
mod selector;

use crate::feature::{Ctx, Feature, Shortcut};
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use image::RgbaImage;
use quick::{Action, Capture};
use std::path::PathBuf;

pub struct CaptureFeature {
    captures: Vec<Capture>,
    selector: Option<selector::Selector>,
    editors: Vec<editor::Editor>,
    clipboard: Option<arboard::Clipboard>,
    cache: Option<PathBuf>,
    next_id: u64,
}

impl CaptureFeature {
    pub fn new() -> Self {
        Self { captures: Vec::new(), selector: None, editors: Vec::new(), clipboard: None, cache: None, next_id: 1 }
    }

    fn add(&mut self, image: RgbaImage, scale: f32, ctx: &mut Ctx) {
        let id = self.next_id;
        self.next_id += 1;
        let dir = self.cache.clone().unwrap_or_else(|| grab::cache_dir(ctx.data_dir));
        let cache_path = dir.join(format!("{id}-{}", grab::file_name("Screenshot", grab::now_secs(), "png")));
        if let Err(e) = grab::write_png(&cache_path, &image) {
            log::error!("capture cache: {e}");
        }
        self.captures.push(Capture { id, image, cache_path, saved_path: None, scale, texture: None });
    }

    fn remove(&mut self, id: u64) {
        if let Some(i) = self.captures.iter().position(|c| c.id == id) {
            let c = self.captures.remove(i);
            let _ = std::fs::remove_file(&c.cache_path);
        }
        self.editors.retain(|e| e.cap_id != id);
    }

    fn copy(&mut self, img: &RgbaImage, ctx: &mut Ctx) {
        if self.clipboard.is_none() {
            self.clipboard = arboard::Clipboard::new().map_err(|e| log::error!("clipboard: {e}")).ok();
        }
        let Some(cb) = &mut self.clipboard else { return };
        let data = arboard::ImageData { width: img.width() as usize, height: img.height() as usize, bytes: img.as_raw().as_slice().into() };
        match cb.set_image(data) {
            Ok(()) => ctx.hud.push("Copied".into()),
            Err(e) => {
                log::error!("copy image: {e}");
                ctx.hud.push("Couldn't copy".into());
            }
        }
    }

    /// Save dialog starting on the Desktop (or straight to `existing`).
    fn save(img: &RgbaImage, existing: Option<PathBuf>, ctx: &mut Ctx) -> Option<PathBuf> {
        let path = existing.or_else(|| {
            let mut d = rfd::FileDialog::new().add_filter("PNG image", &["png"]).set_file_name(grab::file_name("Screenshot", grab::now_secs(), "png"));
            if let Some(desk) = grab::desktop_dir() {
                d = d.set_directory(desk);
            }
            d.save_file().map(grab::with_png_ext)
        })?;
        match grab::write_png(&path, img) {
            Ok(()) => {
                ctx.hud.push("Saved".into());
                Some(path)
            }
            Err(e) => {
                log::error!("save {}: {e}", path.display());
                ctx.hud.push("Couldn't save".into());
                None
            }
        }
    }

    fn area(&mut self, ctx: &mut Ctx) {
        if grab::is_wayland() {
            log::warn!("area capture needs X11; Wayland doesn't allow the overlay");
            ctx.hud.push("Area capture needs an X11 session".into());
            return;
        }
        match grab::grab_all() {
            Ok(shots) => self.selector = Some(selector::Selector::new(shots)),
            Err(e) => {
                log::error!("capture: {e}");
                ctx.hud.push("Screen capture failed".into());
            }
        }
    }

    fn full(&mut self, ctx: &mut Ctx) {
        let shot = grab::pointer_monitor().ok_or_else(|| anyhow::anyhow!("no monitor")).and_then(|m| grab::grab_monitor(&m));
        match shot {
            Ok(s) => self.add(s.image, s.scale, ctx),
            Err(e) => {
                log::error!("capture: {e}");
                ctx.hud.push("Screen capture failed".into());
            }
        }
    }

    fn handle(&mut self, a: Action, ctx: &mut Ctx) {
        let id = match a {
            Action::Copy(id) | Action::Save(id) | Action::Trash(id) | Action::Close(id) | Action::Edit(id) => id,
        };
        let Some(i) = self.captures.iter().position(|c| c.id == id) else { return };
        match a {
            Action::Copy(_) => {
                let img = self.captures[i].image.clone();
                self.copy(&img, ctx);
            }
            Action::Save(_) => {
                if Self::save(&self.captures[i].image, None, ctx).is_some() {
                    self.remove(id);
                }
            }
            Action::Trash(_) | Action::Close(_) => self.remove(id),
            Action::Edit(_) => {
                if !self.editors.iter().any(|e| e.cap_id == id) {
                    let c = &self.captures[i];
                    self.editors.push(editor::Editor::new(id, c.image.clone(), c.scale));
                }
            }
        }
    }

    fn clear(&mut self) {
        self.selector = None;
        self.editors.clear();
        for c in self.captures.drain(..) {
            let _ = std::fs::remove_file(&c.cache_path);
        }
    }
}

impl Feature for CaptureFeature {
    fn id(&self) -> &'static str {
        "capture"
    }
    fn title(&self) -> &'static str {
        "Screenshots"
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        vec![
            Shortcut { id: "area", label: "Capture area or window", default: HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Digit4) },
            Shortcut { id: "full", label: "Capture full screen", default: HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Digit3) },
        ]
    }
    fn set_enabled(&mut self, on: bool, ctx: &mut Ctx) {
        if on {
            let dir = grab::cache_dir(ctx.data_dir);
            // Leftovers from a crash are unsaved captures nobody can reach any more.
            let _ = std::fs::remove_dir_all(&dir);
            if let Err(e) = std::fs::create_dir_all(&dir) {
                log::error!("capture cache {}: {e}", dir.display());
            }
            self.cache = Some(dir);
        } else {
            self.clear();
        }
    }
    fn on_shortcut(&mut self, id: &str, ctx: &mut Ctx) {
        if self.selector.is_some() {
            return;
        }
        match id {
            "area" => self.area(ctx),
            "full" => self.full(ctx),
            _ => {}
        }
    }
    fn update(&mut self, ctx: &mut Ctx) {
        if let Some(sel) = &mut self.selector {
            match sel.show(ctx.egui) {
                selector::Outcome::Pending => {}
                selector::Outcome::Cancel => self.selector = None,
                selector::Outcome::Done(img, scale) => {
                    self.selector = None;
                    self.add(img, scale, ctx);
                }
            }
        }
        for a in quick::show(ctx.egui, &mut self.captures) {
            self.handle(a, ctx);
        }
        let mut i = 0;
        while i < self.editors.len() {
            let events = self.editors[i].show(ctx.egui);
            let id = self.editors[i].cap_id;
            let mut closed = false;
            for e in events {
                match e {
                    editor::Event::Copy(img) => self.copy(&img, ctx),
                    editor::Event::Save(img) => {
                        let existing = self.captures.iter().find(|c| c.id == id).and_then(|c| c.saved_path.clone());
                        if let Some(p) = Self::save(&img, existing, ctx) {
                            if let Some(c) = self.captures.iter_mut().find(|c| c.id == id) {
                                c.saved_path = Some(p);
                            }
                        }
                    }
                    editor::Event::Close(img) => {
                        if let Some(c) = self.captures.iter_mut().find(|c| c.id == id) {
                            if let Err(e) = grab::write_png(&c.cache_path, &img) {
                                log::error!("capture cache: {e}");
                            }
                            c.image = img;
                            c.texture = None;
                        }
                        closed = true;
                    }
                }
            }
            if closed {
                self.editors.remove(i);
            } else {
                i += 1;
            }
        }
        if self.selector.is_some() || !self.editors.is_empty() {
            ctx.egui.request_repaint();
        }
    }
    fn shutdown(&mut self) {
        self.clear();
    }
}
