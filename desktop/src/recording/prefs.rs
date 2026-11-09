//! The bar's last choices, kept in recording.json in the data folder.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Prefs {
    #[serde(default)]
    pub camera: bool,
    #[serde(default)]
    pub mic: bool,
    #[serde(default)]
    pub keys: bool,
}

fn path(dir: &Path) -> PathBuf {
    dir.join("recording.json")
}

impl Prefs {
    pub fn load(dir: &Path) -> Self {
        std::fs::read(path(dir)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    pub fn save(&self, dir: &Path) {
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            if let Err(e) = std::fs::write(path(dir), json) {
                log::warn!("recording prefs: {e}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Prefs::load(dir.path()), Prefs::default());
        let p = Prefs { camera: true, mic: false, keys: true };
        p.save(dir.path());
        assert_eq!(Prefs::load(dir.path()), p);
    }
}
