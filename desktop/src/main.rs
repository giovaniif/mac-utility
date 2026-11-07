//! Windows and Linux port of Mac Utility. The macOS app stays in Swift
//! under MacUtility/; this binary covers the other two platforms.

mod app;
mod autostart;
mod capture;
mod clipboard;
mod feature;
mod keyboard_clean;
mod recording;
mod settings;
mod shortcut_label;
mod tray;

use eframe::egui;

/// Every feature, in tray/Settings order. Feature modules add themselves here.
fn features() -> Vec<Box<dyn feature::Feature>> {
    vec![
        Box::new(keyboard_clean::KeyboardCleanFeature::new()),
        Box::new(clipboard::ClipboardFeature::new()),
        Box::new(capture::CaptureFeature::new()),
        Box::new(recording::RecordingFeature::new()),
    ]
}

fn main() -> anyhow::Result<()> {
    env_logger::init();
    let dirs = directories::ProjectDirs::from("com", "giovani", "MacUtility")
        .ok_or_else(|| anyhow::anyhow!("no data directory"))?;
    let data_dir = dirs.data_dir().to_path_buf();
    std::fs::create_dir_all(&data_dir)?;

    let app = app::App::new(features(), data_dir)?;
    let _tray = tray::spawn(app.tray_items())?;

    // The root window only drives the event loop: tiny, invisible, click-through.
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Utility")
            .with_inner_size([1.0, 1.0])
            .with_position([-10_000.0, -10_000.0])
            .with_decorations(false)
            .with_transparent(true)
            .with_taskbar(false)
            .with_mouse_passthrough(true),
        run_and_return: false,
        ..Default::default()
    };
    eframe::run_native("Utility", options, Box::new(|_| Ok(Box::new(app))))
        .map_err(|e| anyhow::anyhow!("{e}"))
}
