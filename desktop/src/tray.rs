//! Tray icon. On Linux it needs a GTK main loop, so it lives on its own thread
//! there; menu clicks reach the app through `MenuEvent::receiver()` by id.

use tray_icon::menu::{CheckMenuItem, Menu, MenuId, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

pub enum Item {
    Action { id: String, label: String },
    Toggle { id: String, label: String, checked: bool },
}

fn build(items: Vec<Item>) -> anyhow::Result<TrayIcon> {
    let menu = Menu::new();
    for item in items {
        match item {
            Item::Action { id, label } => menu.append(&MenuItem::with_id(MenuId::new(id), label, true, None))?,
            Item::Toggle { id, label, checked } => {
                menu.append(&CheckMenuItem::with_id(MenuId::new(id), label, true, checked, None))?
            }
        }
    }
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&MenuItem::with_id(MenuId::new("settings"), "Settings…", true, None))?;
    menu.append(&MenuItem::with_id(MenuId::new("quit"), "Quit", true, None))?;
    Ok(TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip("Utility").with_icon(icon()).build()?)
}

/// Keep the returned handle alive for the life of the app.
pub fn spawn(items: Vec<Item>) -> anyhow::Result<Option<TrayIcon>> {
    #[cfg(target_os = "linux")]
    {
        std::thread::spawn(move || {
            if gtk::init().is_err() {
                log::error!("gtk init failed; no tray icon");
                return;
            }
            match build(items) {
                Ok(tray) => {
                    gtk::main();
                    drop(tray);
                }
                Err(e) => log::error!("tray failed: {e}"),
            }
        });
        Ok(None)
    }
    #[cfg(not(target_os = "linux"))]
    {
        build(items).map(Some)
    }
}

/// The app icon, from the macOS asset catalog.
fn icon() -> Icon {
    let png = include_bytes!("../../MacUtility/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png");
    let img = image::load_from_memory(png).expect("icon").into_rgba8();
    let (w, h) = img.dimensions();
    Icon::from_rgba(img.into_raw(), w, h).expect("icon")
}
