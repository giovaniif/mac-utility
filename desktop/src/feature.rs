//! The contract every feature module implements. The app shell in app.rs
//! owns the event loop, tray, global hotkeys and settings; features plug in
//! through this trait and are registered in `features::all()` in main.rs.

use global_hotkey::hotkey::HotKey;

/// A shortcut a feature listens for. `id` is stable and used as the settings
/// key; `default` is the out-of-the-box binding (users can rebind it).
pub struct Shortcut {
    pub id: &'static str,
    pub label: &'static str,
    pub default: HotKey,
}

/// Shared services handed to features each frame.
pub struct Ctx<'a> {
    pub egui: &'a eframe::egui::Context,
    /// Per-app data folder (%APPDATA%\giovani\MacUtility or ~/.local/share/macutility).
    pub data_dir: &'a std::path::Path,
    /// Ask the shell to show a short message near the pointer (the macOS HUD).
    pub hud: &'a mut Vec<String>,
}

pub trait Feature {
    /// Stable id, also the settings key. e.g. "clipboard".
    fn id(&self) -> &'static str;
    /// Name in the tray menu and Settings.
    fn title(&self) -> &'static str;
    /// Whether it's on when no setting is saved yet.
    fn enabled_by_default(&self) -> bool {
        true
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        Vec::new()
    }
    /// Called when the feature is switched on (also at launch if on) and off.
    fn set_enabled(&mut self, _on: bool, _ctx: &mut Ctx) {}
    /// A registered shortcut fired. Only called while enabled.
    fn on_shortcut(&mut self, _id: &str, _ctx: &mut Ctx) {}
    /// Called every frame (at least every 100 ms) while enabled. Draw any
    /// overlay/panel windows here with `ctx.egui.show_viewport_immediate`.
    fn update(&mut self, _ctx: &mut Ctx) {}
    /// Extra controls in this feature's Settings section.
    fn settings_ui(&mut self, _ui: &mut eframe::egui::Ui, _ctx: &mut Ctx) {}
    /// A one-shot action listed in the tray menu (e.g. "Start keyboard cleaning").
    fn tray_action(&self) -> Option<&'static str> {
        None
    }
    fn on_tray_action(&mut self, _ctx: &mut Ctx) {}
    /// Restore anything the feature changed (parked windows, blocked keys) before quit.
    fn shutdown(&mut self) {}
}
