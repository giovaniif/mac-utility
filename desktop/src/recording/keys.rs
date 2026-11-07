//! Keystroke labels and the pill's recent-keys log, shared by the Windows
//! hook and the X11 poller.

use std::time::{Duration, Instant};

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stroke {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub meta: bool,
    pub key: String,
}

impl Stroke {
    pub fn label(&self) -> String {
        let mut parts: Vec<&str> = Vec::new();
        if self.ctrl {
            parts.push("Ctrl");
        }
        if self.alt {
            parts.push("Alt");
        }
        if self.shift {
            parts.push("Shift");
        }
        if self.meta {
            parts.push(if cfg!(windows) { "Win" } else { "Super" });
        }
        parts.push(&self.key);
        parts.join("+")
    }
}

/// How long a burst stays on screen after the last key.
pub const LINGER: Duration = Duration::from_millis(1500);
const MAX_SHOWN: usize = 6;

#[derive(Default)]
pub struct KeyLog {
    entries: Vec<(String, Instant)>,
}

impl KeyLog {
    pub fn push(&mut self, s: &Stroke, at: Instant) {
        self.entries.push((s.label(), at));
        if self.entries.len() > 32 {
            self.entries.drain(..self.entries.len() - 32);
        }
    }

    /// The current burst: strokes typed with gaps under LINGER, while the
    /// last one is younger than LINGER.
    pub fn text(&self, now: Instant) -> Option<String> {
        let last = self.entries.last()?.1;
        if now.duration_since(last) > LINGER {
            return None;
        }
        let mut start = self.entries.len() - 1;
        while start > 0 && self.entries[start].1.duration_since(self.entries[start - 1].1) <= LINGER {
            start -= 1;
        }
        let shown = &self.entries[start.max(self.entries.len().saturating_sub(MAX_SHOWN))..];
        Some(shown.iter().map(|e| e.0.as_str()).collect::<Vec<_>>().join("  "))
    }
}

/// Windows virtual-key code to label; None for modifiers.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn vk_label(vk: u32) -> Option<String> {
    let s = match vk {
        0x10 | 0x11 | 0x12 | 0x5B | 0x5C | 0xA0..=0xA5 | 0x14 => return None,
        0x30..=0x39 | 0x41..=0x5A => return Some(char::from(vk as u8).to_string()),
        0x70..=0x87 => return Some(format!("F{}", vk - 0x6F)),
        0x60..=0x69 => return Some(format!("Num{}", vk - 0x60)),
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0D => "Enter",
        0x1B => "Esc",
        0x20 => "Space",
        0x21 => "PgUp",
        0x22 => "PgDn",
        0x23 => "End",
        0x24 => "Home",
        0x25 => "←",
        0x26 => "↑",
        0x27 => "→",
        0x28 => "↓",
        0x2C => "PrtSc",
        0x2D => "Ins",
        0x2E => "Del",
        0xBA => ";",
        0xBB => "=",
        0xBC => ",",
        0xBD => "-",
        0xBE => ".",
        0xBF => "/",
        0xC0 => "`",
        0xDB => "[",
        0xDC => "\\",
        0xDD => "]",
        0xDE => "'",
        _ => return Some(format!("0x{vk:02X}")),
    };
    Some(s.to_string())
}

/// X11 keysym to label; None for modifiers.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn keysym_label(sym: u32) -> Option<String> {
    let s = match sym {
        0xffe1..=0xffee | 0xfe03 => return None,
        0x21..=0x7e => return Some(char::from(sym as u8).to_ascii_uppercase().to_string()),
        0xffbe..=0xffd5 => return Some(format!("F{}", sym - 0xffbd)),
        0x20 => "Space",
        0xff08 => "Backspace",
        0xff09 => "Tab",
        0xff0d | 0xff8d => "Enter",
        0xff1b => "Esc",
        0xff50 => "Home",
        0xff51 => "←",
        0xff52 => "↑",
        0xff53 => "→",
        0xff54 => "↓",
        0xff55 => "PgUp",
        0xff56 => "PgDn",
        0xff57 => "End",
        0xff63 => "Ins",
        0xffff => "Del",
        0 => return None,
        _ => return Some(format!("0x{sym:x}")),
    };
    Some(s.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        let s = Stroke { ctrl: true, shift: true, key: "S".into(), ..Default::default() };
        assert_eq!(s.label(), "Ctrl+Shift+S");
        assert_eq!(vk_label(0x41).as_deref(), Some("A"));
        assert_eq!(vk_label(0x71).as_deref(), Some("F2"));
        assert_eq!(vk_label(0xA2), None);
        assert_eq!(keysym_label(0x61).as_deref(), Some("A"));
        assert_eq!(keysym_label(0xffbe).as_deref(), Some("F1"));
        assert_eq!(keysym_label(0xffe3), None);
        assert_eq!(keysym_label(0xff0d).as_deref(), Some("Enter"));
    }

    #[test]
    fn bursts() {
        let t0 = Instant::now();
        let k = |c: &str| Stroke { key: c.into(), ..Default::default() };
        let mut log = KeyLog::default();
        assert_eq!(log.text(t0), None);
        log.push(&k("A"), t0);
        log.push(&k("B"), t0 + Duration::from_millis(500));
        assert_eq!(log.text(t0 + Duration::from_millis(600)).as_deref(), Some("A  B"));
        // a long gap starts a new burst
        log.push(&k("C"), t0 + Duration::from_secs(5));
        assert_eq!(log.text(t0 + Duration::from_secs(5)).as_deref(), Some("C"));
        assert_eq!(log.text(t0 + Duration::from_secs(8)), None);
        for i in 0..10 {
            log.push(&k(&i.to_string()), t0 + Duration::from_secs(5) + Duration::from_millis(10 * i));
        }
        assert_eq!(log.text(t0 + Duration::from_secs(5) + Duration::from_millis(100)).as_deref(), Some("4  5  6  7  8  9"));
    }
}
