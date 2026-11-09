//! Shared capture helpers: monitors, windows, pointer, cropping, the cache
//! folder and file naming. Public so the recorder can reuse them.
#![allow(dead_code)]

use image::RgbaImage;
use std::path::{Path, PathBuf};

/// A frozen image of one monitor plus its geometry in physical desktop pixels.
pub struct Shot {
    pub image: RgbaImage,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f32,
}

/// Monitor geometry without pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f32,
}

/// A top-level window rectangle in physical desktop pixels; higher `z` is on top.
#[derive(Clone, Debug, PartialEq)]
pub struct WinRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub z: i32,
    pub title: String,
}

impl WinRect {
    pub fn contains(&self, px: i32, py: i32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.width as i32 && py < self.y + self.height as i32
    }
}

/// True on a Linux Wayland session, where global pointer and overlay
/// placement are not available.
pub fn is_wayland() -> bool {
    cfg!(target_os = "linux")
        && (std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").map(|s| s == "wayland").unwrap_or(false))
}

fn monitor_rect(m: &xcap::Monitor) -> Option<MonitorRect> {
    Some(MonitorRect {
        x: m.x().ok()?,
        y: m.y().ok()?,
        width: m.width().ok()?,
        height: m.height().ok()?,
        scale: m.scale_factor().ok().filter(|s| *s > 0.0).unwrap_or(1.0),
    })
}

pub fn grab_monitor(m: &xcap::Monitor) -> anyhow::Result<Shot> {
    let r = monitor_rect(m).ok_or_else(|| anyhow::anyhow!("monitor geometry unavailable"))?;
    let image = m.capture_image()?;
    Ok(Shot { image, x: r.x, y: r.y, width: r.width, height: r.height, scale: r.scale })
}

/// Freeze every monitor.
pub fn grab_all() -> anyhow::Result<Vec<Shot>> {
    let shots: Vec<Shot> = xcap::Monitor::all()?.iter().filter_map(|m| grab_monitor(m).map_err(|e| log::warn!("capture monitor: {e}")).ok()).collect();
    if shots.is_empty() {
        anyhow::bail!("no monitor could be captured");
    }
    Ok(shots)
}

/// The monitor under the pointer, else the primary one, else the first.
pub fn pointer_monitor() -> Option<xcap::Monitor> {
    if let Some((x, y)) = cursor_pos() {
        if let Ok(m) = xcap::Monitor::from_point(x, y) {
            return Some(m);
        }
    }
    let all = xcap::Monitor::all().ok()?;
    let primary = all.iter().position(|m| m.is_primary().unwrap_or(false)).unwrap_or(0);
    all.into_iter().nth(primary)
}

pub fn pointer_monitor_rect() -> Option<MonitorRect> {
    pointer_monitor().and_then(|m| monitor_rect(&m))
}

/// Visible top-level windows of other processes, topmost first.
pub fn window_rects() -> Vec<WinRect> {
    let me = std::process::id();
    let mut out: Vec<WinRect> = xcap::Window::all()
        .unwrap_or_default()
        .iter()
        .filter(|w| w.pid().map(|p| p != me).unwrap_or(true) && !w.is_minimized().unwrap_or(false))
        .filter_map(|w| {
            Some(WinRect {
                x: w.x().ok()?,
                y: w.y().ok()?,
                width: w.width().ok()?,
                height: w.height().ok()?,
                z: w.z().unwrap_or(0),
                title: w.title().unwrap_or_default(),
            })
        })
        .filter(|w| w.width > 1 && w.height > 1)
        .collect();
    out.sort_by(|a, b| b.z.cmp(&a.z));
    out
}

/// Topmost window containing the point (`rects` sorted topmost first).
pub fn window_at(rects: &[WinRect], x: i32, y: i32) -> Option<&WinRect> {
    rects.iter().find(|w| w.contains(x, y))
}

/// Crop a desktop rectangle (physical pixels) out of a monitor shot. The
/// image may be at a different resolution than the geometry; scale between them.
pub fn crop_shot(shot: &Shot, x: i32, y: i32, w: u32, h: u32) -> Option<RgbaImage> {
    let kx = shot.image.width() as f32 / shot.width.max(1) as f32;
    let ky = shot.image.height() as f32 / shot.height.max(1) as f32;
    let x0 = (((x - shot.x) as f32) * kx).round().max(0.0) as u32;
    let y0 = (((y - shot.y) as f32) * ky).round().max(0.0) as u32;
    let x1 = ((((x - shot.x) as f32 + w as f32) * kx).round().max(0.0) as u32).min(shot.image.width());
    let y1 = ((((y - shot.y) as f32 + h as f32) * ky).round().max(0.0) as u32).min(shot.image.height());
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some(image::imageops::crop_imm(&shot.image, x0, y0, x1 - x0, y1 - y0).to_image())
}

/// Global pointer position in physical desktop pixels.
#[cfg(windows)]
pub fn cursor_pos() -> Option<(i32, i32)> {
    use windows::Win32::Foundation::POINT;
    use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p) }.ok()?;
    Some((p.x, p.y))
}

#[cfg(target_os = "linux")]
pub fn cursor_pos() -> Option<(i32, i32)> {
    use std::sync::OnceLock;
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::ConnectionExt;
    use x11rb::rust_connection::RustConnection;
    static CONN: OnceLock<Option<(RustConnection, u32)>> = OnceLock::new();
    if is_wayland() && std::env::var_os("DISPLAY").is_none() {
        return None;
    }
    let (conn, root) = CONN
        .get_or_init(|| {
            let (conn, screen) = x11rb::connect(None).map_err(|e| log::warn!("x11 connect: {e}")).ok()?;
            let root = conn.setup().roots.get(screen)?.root;
            Some((conn, root))
        })
        .as_ref()?;
    let r = conn.query_pointer(*root).ok()?.reply().ok()?;
    Some((r.root_x as i32, r.root_y as i32))
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn cursor_pos() -> Option<(i32, i32)> {
    None
}

/// Folder holding captures until they're saved.
pub fn cache_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("capture-cache")
}

pub fn write_png(path: &Path, img: &RgbaImage) -> anyhow::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    img.save_with_format(path, image::ImageFormat::Png)?;
    Ok(())
}

/// Ensure a save path ends in `.png`.
pub fn with_png_ext(mut p: PathBuf) -> PathBuf {
    if !p.extension().map(|e| e.eq_ignore_ascii_case("png")).unwrap_or(false) {
        let name = format!("{}.png", p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "Screenshot".into()));
        p.set_file_name(name);
    }
    p
}

/// "Screenshot 2026-11-07 at 14.03.09.png" (UTC) for a Unix timestamp.
pub fn file_name(prefix: &str, unix_secs: u64, ext: &str) -> String {
    let days = (unix_secs / 86_400) as i64;
    let secs = unix_secs % 86_400;
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{prefix} {y:04}-{m:02}-{d:02} at {:02}.{:02}.{:02}.{ext}", secs / 3600, secs % 3600 / 60, secs % 60)
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Where Save dialogs start.
pub fn desktop_dir() -> Option<PathBuf> {
    directories::UserDirs::new().and_then(|u| u.desktop_dir().map(Path::to_path_buf))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_by_date() {
        assert_eq!(file_name("Screenshot", 0, "png"), "Screenshot 1970-01-01 at 00.00.00.png");
        assert_eq!(file_name("Screenshot", 1_762_524_189, "png"), "Screenshot 2025-11-07 at 14.03.09.png");
    }

    #[test]
    fn png_extension_added_once() {
        assert_eq!(with_png_ext(PathBuf::from("/a/b")), PathBuf::from("/a/b.png"));
        assert_eq!(with_png_ext(PathBuf::from("/a/b.PNG")), PathBuf::from("/a/b.PNG"));
    }

    #[test]
    fn crop_scales_between_geometry_and_pixels() {
        let shot = Shot { image: RgbaImage::new(200, 100), x: -100, y: 0, width: 100, height: 50, scale: 2.0 };
        let c = crop_shot(&shot, -90, 10, 20, 10).unwrap();
        assert_eq!(c.dimensions(), (40, 20));
        assert!(crop_shot(&shot, 500, 500, 10, 10).is_none());
        let edge = crop_shot(&shot, -10, 40, 50, 50).unwrap();
        assert_eq!(edge.dimensions(), (20, 20));
    }

    #[test]
    fn window_at_prefers_topmost() {
        let a = WinRect { x: 0, y: 0, width: 100, height: 100, z: 1, title: "back".into() };
        let b = WinRect { x: 50, y: 50, width: 100, height: 100, z: 2, title: "front".into() };
        let rects = vec![b.clone(), a.clone()];
        assert_eq!(window_at(&rects, 60, 60).unwrap().title, "front");
        assert_eq!(window_at(&rects, 10, 10).unwrap().title, "back");
        assert!(window_at(&rects, 200, 10).is_none());
    }
}
