use global_hotkey::hotkey::{HotKey, Modifiers};

/// "Ctrl+Shift+V" style label for a hotkey.
pub fn label(key: &HotKey) -> String {
    let mut parts = Vec::new();
    for (m, name) in [
        (Modifiers::CONTROL, "Ctrl"),
        (Modifiers::ALT, "Alt"),
        (Modifiers::SHIFT, "Shift"),
        (Modifiers::SUPER, if cfg!(windows) { "Win" } else { "Super" }),
    ] {
        if key.mods.contains(m) {
            parts.push(name.to_string());
        }
    }
    let code = format!("{:?}", key.key);
    let code = code.strip_prefix("Key").or_else(|| code.strip_prefix("Digit")).unwrap_or(&code).to_string();
    parts.push(code);
    parts.join("+")
}
