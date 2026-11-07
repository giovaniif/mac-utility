//! App shell: a tiny invisible root window drives the egui event loop, the
//! tray menu and global hotkeys dispatch to features, and the Settings
//! window lists every feature with its switch and shortcuts.

use crate::feature::{Ctx, Feature};
use crate::settings::Settings;
use eframe::egui;
use global_hotkey::hotkey::HotKey;
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tray_icon::menu::MenuEvent;

pub struct App {
    features: Vec<Box<dyn Feature>>,
    settings: Settings,
    data_dir: PathBuf,
    hotkeys: GlobalHotKeyManager,
    /// hotkey id -> (feature index, shortcut id)
    bindings: HashMap<u32, (usize, &'static str)>,
    settings_open: bool,
    hud: Vec<String>,
    hud_shown: Option<(String, Instant)>,
    started: bool,
}

impl App {
    pub fn new(features: Vec<Box<dyn Feature>>, data_dir: PathBuf) -> anyhow::Result<Self> {
        let settings = Settings::load(&data_dir);
        let mut app = Self {
            features,
            settings,
            data_dir,
            hotkeys: GlobalHotKeyManager::new()?,
            bindings: HashMap::new(),
            settings_open: false,
            hud: Vec::new(),
            hud_shown: None,
            started: false,
        };
        app.register_hotkeys();
        Ok(app)
    }

    pub fn tray_items(&self) -> Vec<crate::tray::Item> {
        let mut items = Vec::new();
        for f in &self.features {
            if let Some(label) = f.tray_action() {
                items.push(crate::tray::Item::Action { id: format!("action:{}", f.id()), label: label.into() });
            }
        }
        for f in &self.features {
            items.push(crate::tray::Item::Toggle {
                id: format!("toggle:{}", f.id()),
                label: f.title().into(),
                checked: self.is_enabled(f.as_ref()),
            });
        }
        items
    }

    fn is_enabled(&self, f: &dyn Feature) -> bool {
        *self.settings.enabled.get(f.id()).unwrap_or(&f.enabled_by_default())
    }

    pub fn binding(&self, f: &dyn Feature, id: &str, default: HotKey) -> HotKey {
        *self.settings.shortcuts.get(&format!("{}.{}", f.id(), id)).unwrap_or(&default)
    }

    fn register_hotkeys(&mut self) {
        for hk in self.bindings.keys().copied().collect::<Vec<_>>() {
            let _ = hk; // ids only; unregister_all below
        }
        let all: Vec<HotKey> = self
            .features
            .iter()
            .flat_map(|f| f.shortcuts().into_iter().map(|s| self.binding(f.as_ref(), s.id, s.default)))
            .collect();
        let _ = self.hotkeys.unregister_all(&all);
        self.bindings.clear();
        for (i, f) in self.features.iter().enumerate() {
            if !self.is_enabled(f.as_ref()) {
                continue;
            }
            for s in f.shortcuts() {
                let key = self.binding(f.as_ref(), s.id, s.default);
                match self.hotkeys.register(key) {
                    Ok(()) => {
                        self.bindings.insert(key.id(), (i, s.id));
                    }
                    Err(e) => log::warn!("shortcut {} for {} not registered: {e}", key, f.id()),
                }
            }
        }
    }

    fn with_ctx<R>(&mut self, egui: &egui::Context, i: usize, run: impl FnOnce(&mut Box<dyn Feature>, &mut Ctx) -> R) -> R {
        let mut ctx = Ctx { egui, data_dir: &self.data_dir, hud: &mut self.hud };
        run(&mut self.features[i], &mut ctx)
    }

    fn set_enabled(&mut self, egui: &egui::Context, i: usize, on: bool) {
        let id = self.features[i].id().to_string();
        self.settings.enabled.insert(id, on);
        self.settings.save();
        self.with_ctx(egui, i, |f, c| f.set_enabled(on, c));
        self.register_hotkeys();
    }

    fn handle_events(&mut self, egui: &egui::Context) {
        while let Ok(e) = GlobalHotKeyEvent::receiver().try_recv() {
            if e.state != HotKeyState::Pressed {
                continue;
            }
            if let Some(&(i, sid)) = self.bindings.get(&e.id) {
                self.with_ctx(egui, i, |f, c| f.on_shortcut(sid, c));
            }
        }
        while let Ok(e) = MenuEvent::receiver().try_recv() {
            let id = e.id.0.as_str();
            if id == "quit" {
                self.quit();
            } else if id == "settings" {
                self.settings_open = true;
            } else if let Some(fid) = id.strip_prefix("toggle:") {
                if let Some(i) = self.features.iter().position(|f| f.id() == fid) {
                    let on = !self.is_enabled(self.features[i].as_ref());
                    self.set_enabled(egui, i, on);
                }
            } else if let Some(fid) = id.strip_prefix("action:") {
                if let Some(i) = self.features.iter().position(|f| f.id() == fid) {
                    self.with_ctx(egui, i, |f, c| f.on_tray_action(c));
                }
            }
        }
    }

    pub fn quit(&mut self) -> ! {
        for f in &mut self.features {
            f.shutdown();
        }
        std::process::exit(0)
    }

    fn settings_window(&mut self, egui: &egui::Context) {
        if !self.settings_open {
            return;
        }
        let id = egui::ViewportId::from_hash_of("settings");
        let builder = egui::ViewportBuilder::default().with_title("Utility Settings").with_inner_size([520.0, 640.0]);
        egui.show_viewport_immediate(id, builder, |ctx, _| {
            if ctx.input(|i| i.viewport().close_requested()) {
                self.settings_open = false;
            }
            egui::CentralPanel::default().show(ctx, |ui| {
                egui::ScrollArea::vertical().show(ui, |ui| {
                    let mut login = self.settings.launch_at_login;
                    if ui.checkbox(&mut login, "Launch at login").changed() {
                        self.settings.launch_at_login = login;
                        self.settings.save();
                        if let Err(e) = crate::autostart::set(login) {
                            log::error!("launch at login: {e}");
                        }
                    }
                    for i in 0..self.features.len() {
                        ui.separator();
                        let mut on = self.is_enabled(self.features[i].as_ref());
                        if ui.checkbox(&mut on, egui::RichText::new(self.features[i].title()).strong()).changed() {
                            self.set_enabled(ctx, i, on);
                        }
                        for s in self.features[i].shortcuts() {
                            let key = self.binding(self.features[i].as_ref(), s.id, s.default);
                            ui.horizontal(|ui| {
                                ui.label(s.label);
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                    ui.monospace(crate::shortcut_label::label(&key));
                                });
                            });
                        }
                        if on {
                            self.with_ctx(ctx, i, |f, c| {
                                let ui_ctx = c.egui.clone();
                                let _ = ui_ctx;
                                f.settings_ui(ui, c)
                            });
                        }
                    }
                });
            });
        });
    }

    fn hud_window(&mut self, egui: &egui::Context) {
        if let Some(msg) = self.hud.pop() {
            self.hud.clear();
            self.hud_shown = Some((msg, Instant::now()));
        }
        let Some((msg, at)) = self.hud_shown.clone() else { return };
        if at.elapsed() > Duration::from_millis(1400) {
            self.hud_shown = None;
            return;
        }
        let builder = egui::ViewportBuilder::default()
            .with_decorations(false)
            .with_transparent(true)
            .with_always_on_top()
            .with_taskbar(false)
            .with_mouse_passthrough(true)
            .with_inner_size([320.0, 60.0]);
        egui.show_viewport_immediate(egui::ViewportId::from_hash_of("hud"), builder, |ctx, _| {
            egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
                egui::Frame::popup(ui.style()).show(ui, |ui| {
                    ui.centered_and_justified(|ui| ui.heading(&msg));
                });
            });
        });
    }
}

impl eframe::App for App {
    fn update(&mut self, egui: &egui::Context, _frame: &mut eframe::Frame) {
        if !self.started {
            self.started = true;
            for i in 0..self.features.len() {
                if self.is_enabled(self.features[i].as_ref()) {
                    self.with_ctx(egui, i, |f, c| f.set_enabled(true, c));
                }
            }
        }
        self.handle_events(egui);
        for i in 0..self.features.len() {
            if self.is_enabled(self.features[i].as_ref()) {
                self.with_ctx(egui, i, |f, c| f.update(c));
            }
        }
        self.settings_window(egui);
        self.hud_window(egui);
        egui.request_repaint_after(Duration::from_millis(100));
    }

    fn clear_color(&self, _: &egui::Visuals) -> [f32; 4] {
        [0.0; 4]
    }
}
