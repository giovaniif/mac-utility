use global_hotkey::hotkey::HotKey;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Persisted as settings.json in the data folder. Feature-specific values go
/// in `extra` under "<feature id>.<key>".
#[derive(Default, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub enabled: HashMap<String, bool>,
    #[serde(default)]
    pub shortcuts: HashMap<String, HotKey>,
    #[serde(default)]
    pub launch_at_login: bool,
    #[serde(default)]
    pub extra: HashMap<String, serde_json::Value>,
    #[serde(skip)]
    path: PathBuf,
}

impl Settings {
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("settings.json");
        let mut s: Settings = std::fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        s.path = path;
        s
    }

    pub fn save(&self) {
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            if let Err(e) = std::fs::write(&self.path, json) {
                log::error!("settings write failed: {e}");
            }
        }
    }
}
