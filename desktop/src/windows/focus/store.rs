//! Everything Focus keeps on disk. Written on every change, so a crash
//! leaves enough behind to bring parked windows back.

use super::stage::{StageState, WindowId};
use crate::windows::geometry::{self, Rect};
use crate::windows::platform;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Default, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(default)]
    pub state: StageState,
    /// Last on-stage frame of each window.
    #[serde(default)]
    pub homes: HashMap<WindowId, Rect>,
    #[serde(default)]
    pub parked: HashSet<WindowId>,
    /// "app\ttitle" and "app" -> set, for apps that relaunch.
    #[serde(default)]
    pub memory: HashMap<String, usize>,
    /// app -> set: new windows of a pinned app go there.
    #[serde(default)]
    pub pins: HashMap<String, usize>,
    /// True while Focus runs. Still true at launch means it didn't stop cleanly.
    #[serde(default)]
    pub active: bool,
}

fn path(dir: &Path) -> PathBuf {
    dir.join("focus-state.json")
}

pub fn load(dir: &Path) -> Snapshot {
    let mut s: Snapshot = match std::fs::read(path(dir)) {
        Ok(b) => serde_json::from_slice(&b).unwrap_or_else(|e| {
            log::error!("couldn't read focus state: {e}");
            Snapshot::default()
        }),
        Err(_) => Snapshot::default(),
    };
    s.state = s.state.sanitized();
    s
}

pub fn save(dir: &Path, s: &Snapshot) {
    let p = path(dir);
    let tmp = p.with_extension("json.tmp");
    let result = serde_json::to_vec(s)
        .map_err(anyhow::Error::from)
        .and_then(|b| std::fs::write(&tmp, b).map_err(Into::into))
        .and_then(|_| std::fs::rename(&tmp, &p).map_err(Into::into));
    if let Err(e) = result {
        log::error!("couldn't save focus state: {e}");
    }
}

/// Focus isn't going to run but the last session left windows parked: put
/// each one back where it last was.
pub fn recover_if_needed(dir: &Path) {
    let mut s = load(dir);
    if !s.active {
        return;
    }
    log::info!("recovering {} parked windows", s.parked.len());
    if platform::supported().is_ok() {
        let work = platform::monitors().into_iter().find(|m| m.primary).map(|m| m.work);
        for w in platform::windows() {
            if !s.parked.contains(&w.id) {
                continue;
            }
            if let Some(home) = s.homes.get(&w.id) {
                platform::set_frame(w.id, *home);
            } else if let Some(work) = work {
                platform::set_frame(w.id, geometry::center(&w.frame, &work));
            }
        }
    }
    s.parked.clear();
    s.active = false;
    save(dir, &s);
}

/// Focus options from Settings.
#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Prefs {
    /// A lone window stops at this width (logical pixels) and centers.
    #[serde(default = "default_cap")]
    pub width_cap: f64,
    /// Space around and between windows, 0-40 logical pixels.
    #[serde(default = "default_gap")]
    pub gap: f64,
    /// Fade when switching sets.
    #[serde(default = "yes")]
    pub fade: bool,
}

fn default_cap() -> f64 {
    1440.0
}
fn default_gap() -> f64 {
    12.0
}
fn yes() -> bool {
    true
}

impl Default for Prefs {
    fn default() -> Self {
        Self { width_cap: default_cap(), gap: default_gap(), fade: true }
    }
}

impl Prefs {
    pub fn load(dir: &Path) -> Self {
        let mut p: Prefs = std::fs::read(dir.join("focus-settings.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        p.gap = p.gap.clamp(0.0, 40.0);
        if p.width_cap <= 0.0 {
            p.width_cap = default_cap();
        }
        p
    }
    pub fn save(&self, dir: &Path) {
        if let Ok(b) = serde_json::to_vec_pretty(self) {
            if let Err(e) = std::fs::write(dir.join("focus-settings.json"), b) {
                log::error!("couldn't save focus settings: {e}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = Snapshot::default();
        s.state.add(7, None, true);
        s.parked.insert(7);
        s.homes.insert(7, Rect::new(1.0, 2.0, 3.0, 4.0));
        s.active = true;
        save(dir.path(), &s);
        let back = load(dir.path());
        assert_eq!(back.state, s.state);
        assert!(back.parked.contains(&7));
        assert_eq!(back.homes[&7], Rect::new(1.0, 2.0, 3.0, 4.0));
        assert!(back.active);
    }

    #[test]
    fn bad_current_is_sanitized() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("focus-state.json"), r#"{"state":{"sets":[],"current":42}}"#).unwrap();
        let s = load(dir.path());
        assert_eq!(s.state.current, 1);
        assert_eq!(s.state.sets.len(), 9);
    }

    #[test]
    fn prefs_default_and_clamp() {
        let dir = tempfile::tempdir().unwrap();
        assert!(Prefs::load(dir.path()) == Prefs::default());
        std::fs::write(dir.path().join("focus-settings.json"), r#"{"gap":99}"#).unwrap();
        let p = Prefs::load(dir.path());
        assert_eq!(p.gap, 40.0);
        assert_eq!(p.width_cap, 1440.0);
        assert!(p.fade);
    }
}
