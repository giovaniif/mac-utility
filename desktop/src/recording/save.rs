//! Moving a finished recording out of the cache: a Save dialog starting on
//! the Desktop (rfd on Windows, zenity or kdialog on Linux).

use std::path::{Path, PathBuf};

pub fn desktop() -> PathBuf {
    directories::UserDirs::new()
        .and_then(|u| u.desktop_dir().map(Path::to_path_buf))
        .or_else(|| directories::BaseDirs::new().map(|b| b.home_dir().to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(windows)]
fn ask(name: &str) -> Option<PathBuf> {
    rfd::FileDialog::new().set_directory(desktop()).set_file_name(name).add_filter("MPEG-4 movie", &["mp4"]).save_file()
}

#[cfg(not(windows))]
fn ask(name: &str) -> Option<PathBuf> {
    use std::process::Command;
    let default = desktop().join(name);
    let zenity = Command::new("zenity")
        .args(["--file-selection", "--save", "--confirm-overwrite", "--title=Save recording"])
        .arg(format!("--filename={}", default.display()))
        .output();
    let out = match zenity {
        Ok(o) => o,
        Err(_) => match Command::new("kdialog").arg("--getsavefilename").arg(&default).arg("*.mp4").output() {
            Ok(o) => o,
            // No dialog tool: save straight to the Desktop.
            Err(_) => return Some(default),
        },
    };
    let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !path.is_empty()).then(|| PathBuf::from(path))
}

/// Asks where to save and moves the file there. Ok(None) when cancelled.
pub fn save_as(src: &Path) -> Result<Option<PathBuf>, String> {
    let name = src.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "Recording.mp4".into());
    let Some(mut dest) = ask(&name) else { return Ok(None) };
    if dest.extension().is_none() {
        dest.set_extension("mp4");
    }
    if std::fs::rename(src, &dest).is_err() {
        std::fs::copy(src, &dest).map_err(|e| format!("Couldn't save: {e}"))?;
        let _ = std::fs::remove_file(src);
    }
    Ok(Some(dest))
}
