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
