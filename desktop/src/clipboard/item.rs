use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Text,
    RichText,
    Image,
    Files,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Text => "text",
            Kind::RichText => "richText",
            Kind::Image => "image",
            Kind::Files => "files",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "text" => Kind::Text,
            "richText" => Kind::RichText,
            "image" => Kind::Image,
            "files" => Kind::Files,
            _ => return None,
        })
    }
}

/// One captured clipboard entry. Image bytes live in files next to the
/// history; everything else is stored inline. Mirrors ClipboardItem.swift.
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardItem {
    pub id: Uuid,
    pub kind: Kind,
    /// Plain text, also the fallback for rich text and the search key.
    pub text: Option<String>,
    pub html: Option<String>,
    /// File names inside the images folder.
    pub image_file: Option<String>,
    pub thumbnail_file: Option<String>,
    pub files: Vec<String>,
    /// Executable name of the app the item came from.
    pub source_app: Option<String>,
    /// Seconds since the Unix epoch.
    pub date: f64,
    pub pinned: bool,
    /// Identity used to collapse duplicates.
    pub fingerprint: String,
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

impl ClipboardItem {
    pub fn text(text: String, html: Option<String>, source_app: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind: if html.is_some() { Kind::RichText } else { Kind::Text },
            fingerprint: format!("text:{text}"),
            text: Some(text),
            html,
            image_file: None,
            thumbnail_file: None,
            files: Vec::new(),
            source_app,
            date: now(),
            pinned: false,
        }
    }

    pub fn files(files: Vec<String>, source_app: Option<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind: Kind::Files,
            fingerprint: format!("files:{}", files.join("\n")),
            text: None,
            html: None,
            image_file: None,
            thumbnail_file: None,
            files,
            source_app,
            date: now(),
            pinned: false,
        }
    }

    /// Text written for a plain-text paste.
    pub fn plain_text(&self) -> String {
        match self.kind {
            Kind::Files => self.files.join("\n"),
            _ => self.text.clone().unwrap_or_default(),
        }
    }

    pub fn search_text(&self) -> String {
        match self.kind {
            Kind::Text | Kind::RichText => self.text.clone().unwrap_or_default(),
            Kind::Image => "image".into(),
            Kind::Files => self
                .files
                .iter()
                .map(|p| p.rsplit(['/', '\\']).next().unwrap_or(p))
                .collect::<Vec<_>>()
                .join(" "),
        }
    }
}

/// Password managers whose copies are never recorded, by executable name.
const EXCLUDED_APPS: [&str; 5] = ["1password", "keepass", "keepassxc", "keepassx", "bitwarden"];

pub fn is_excluded_app(exe: &str) -> bool {
    let name = exe.rsplit(['/', '\\']).next().unwrap_or(exe).to_lowercase();
    let name = name.strip_suffix(".exe").unwrap_or(&name);
    EXCLUDED_APPS.contains(&name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excluded_apps() {
        assert!(is_excluded_app("1Password.exe"));
        assert!(is_excluded_app("KeePassXC"));
        assert!(is_excluded_app("C:\\Program Files\\Bitwarden\\Bitwarden.exe"));
        assert!(is_excluded_app("keepass"));
        assert!(!is_excluded_app("notepad.exe"));
        assert!(!is_excluded_app("1passwordish"));
    }

    #[test]
    fn files_item() {
        let item = ClipboardItem::files(vec!["/a/b.txt".into(), "/c/d.png".into()], None);
        assert_eq!(item.fingerprint, "files:/a/b.txt\n/c/d.png");
        assert_eq!(item.search_text(), "b.txt d.png");
        assert_eq!(item.plain_text(), "/a/b.txt\n/c/d.png");
    }
}
