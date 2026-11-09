//! Installed apps for the picker's `/` search: Start Menu shortcuts on
//! Windows, .desktop entries on Linux.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct InstalledApp {
    pub name: String,
    /// The .lnk or .desktop file; launching opens it.
    pub path: PathBuf,
}

fn roots() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if cfg!(windows) {
        for var in ["ProgramData", "APPDATA"] {
            if let Some(base) = std::env::var_os(var) {
                out.push(PathBuf::from(base).join("Microsoft\\Windows\\Start Menu\\Programs"));
            }
        }
    } else {
        let home = std::env::var_os("HOME").map(PathBuf::from);
        let data_home = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).or_else(|| home.as_ref().map(|h| h.join(".local/share")));
        if let Some(d) = data_home {
            out.push(d.join("applications"));
            out.push(d.join("flatpak/exports/share/applications"));
        }
        let dirs = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
        for d in dirs.split(':').filter(|d| !d.is_empty()) {
            out.push(Path::new(d).join("applications"));
        }
        out.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    }
    out
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<InstalledApp>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            if depth < 3 {
                walk(&p, depth + 1, out);
            }
            continue;
        }
        let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
        if ext == "lnk" {
            let name = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if !name.to_lowercase().contains("uninstall") {
                out.push(InstalledApp { name, path: p });
            }
        } else if ext == "desktop" {
            if let Some((name, _)) = std::fs::read_to_string(&p).ok().as_deref().and_then(parse_desktop) {
                out.push(InstalledApp { name, path: p });
            }
        }
    }
}

/// Every installed app, by name, without duplicates. Slow-ish: call off the UI thread.
pub fn scan() -> Vec<InstalledApp> {
    let mut out = Vec::new();
    for r in roots() {
        walk(&r, 0, &mut out);
    }
    out.sort_by_key(|a| a.name.to_lowercase());
    out.dedup_by(|a, b| a.name.eq_ignore_ascii_case(&b.name));
    out
}

/// Name and Exec of a launchable desktop entry; None for hidden ones.
pub fn parse_desktop(text: &str) -> Option<(String, String)> {
    let mut in_entry = false;
    let (mut name, mut exec, mut app) = (None, None, false);
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        match k.trim() {
            "Name" if name.is_none() => name = Some(v.trim().to_string()),
            "Exec" if exec.is_none() => exec = Some(v.trim().to_string()),
            "Type" => app = v.trim() == "Application",
            "NoDisplay" | "Hidden" if v.trim() == "true" => return None,
            _ => {}
        }
    }
    if !app {
        return None;
    }
    Some((name?, exec?))
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
/// The Exec line with %f/%U-style field codes dropped.
pub fn desktop_exec(text: &str) -> Option<String> {
    let (_, exec) = parse_desktop(text)?;
    let mut out = String::new();
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '%' {
            match chars.next() {
                Some('%') => out.push('%'),
                _ => continue,
            }
        } else {
            out.push(c);
        }
    }
    let out = out.split_whitespace().collect::<Vec<_>>().join(" ");
    (!out.is_empty()).then_some(out)
}

/// Apps whose name contains the query, names starting with it first, at most 12.
pub fn search<'a>(apps: &'a [InstalledApp], query: &str) -> Vec<&'a InstalledApp> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Vec::new();
    }
    let mut hits: Vec<&InstalledApp> = apps.iter().filter(|a| a.name.to_lowercase().contains(&q)).collect();
    hits.sort_by_key(|a| !a.name.to_lowercase().starts_with(&q));
    hits.truncate(12);
    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIREFOX: &str = "[Desktop Entry]\nType=Application\nName=Firefox\nName[de]=Feuerfuchs\nExec=firefox %u\n\n[Desktop Action new]\nName=New Window\nExec=firefox --new-window %u\n";

    #[test]
    fn parses_name_and_exec() {
        assert_eq!(parse_desktop(FIREFOX), Some(("Firefox".into(), "firefox %u".into())));
        assert_eq!(desktop_exec(FIREFOX), Some("firefox".into()));
    }

    #[test]
    fn skips_hidden_and_non_apps() {
        assert_eq!(parse_desktop("[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n"), None);
        assert_eq!(parse_desktop("[Desktop Entry]\nType=Link\nName=X\nURL=y\n"), None);
    }

    #[test]
    fn keeps_literal_percent() {
        assert_eq!(desktop_exec("[Desktop Entry]\nType=Application\nName=A\nExec=a --x=100%% %F\n"), Some("a --x=100%".into()));
    }

    #[test]
    fn search_ranks_prefix_first() {
        let app = |n: &str| InstalledApp { name: n.into(), path: PathBuf::new() };
        let apps = vec![app("Google Chrome"), app("Chromium"), app("Notes")];
        let names: Vec<_> = search(&apps, "chr").into_iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, vec!["Chromium", "Google Chrome"]);
        assert!(search(&apps, " ").is_empty());
    }
}
