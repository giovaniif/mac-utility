//! Keyboard cleaning mode: blocks every key, shows a full-screen overlay on
//! every monitor with a countdown and an unlock switch, and unlocks by itself
//! after the timeout. The overlay switch (mouse) is the way out; the shortcut
//! can't fire while keys are blocked.

mod blocker;
mod overlay;

use crate::feature::{Ctx, Feature, Shortcut};
use blocker::Blocker;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(60);

/// A monitor rectangle in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorRect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

/// Whole seconds left, rounded up, as the countdown shows them.
pub fn remaining_secs(deadline: Instant, now: Instant) -> u64 {
    let left = deadline.saturating_duration_since(now);
    let whole = left.as_secs();
    if left.subsec_nanos() > 0 {
        whole + 1
    } else {
        whole
    }
}

struct Session {
    deadline: Instant,
    // Dropping the blocker releases the keyboard.
    _blocker: Blocker,
    monitors: Vec<MonitorRect>,
}

pub struct KeyboardCleanFeature {
    session: Option<Session>,
}

impl KeyboardCleanFeature {
    pub fn new() -> Self {
        blocker::install_panic_hook();
        Self { session: None }
    }

    fn toggle(&mut self, ctx: &mut Ctx) {
        if self.session.is_some() {
            self.unlock();
        } else {
            self.lock(ctx);
        }
    }

    fn lock(&mut self, ctx: &mut Ctx) {
        match Blocker::start() {
            Ok(b) => {
                self.session = Some(Session {
                    deadline: Instant::now() + TIMEOUT,
                    _blocker: b,
                    monitors: blocker::monitors(),
                });
                log::info!("keyboard locked for {}s", TIMEOUT.as_secs());
            }
            Err(e) => {
                log::warn!("keyboard cleaning unavailable: {e}");
                ctx.hud.push(e);
            }
        }
    }

    fn unlock(&mut self) {
        if self.session.take().is_some() {
            log::info!("keyboard unlocked");
        }
    }
}

impl Feature for KeyboardCleanFeature {
    fn id(&self) -> &'static str {
        "keyboard_clean"
    }
    fn title(&self) -> &'static str {
        "Keyboard cleaning"
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        vec![Shortcut {
            id: "toggle",
            label: "Start keyboard cleaning",
            default: HotKey::new(Some(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER), Code::KeyK),
        }]
    }
    fn set_enabled(&mut self, on: bool, _ctx: &mut Ctx) {
        if !on {
            self.unlock();
        }
    }
    fn on_shortcut(&mut self, _id: &str, ctx: &mut Ctx) {
        self.toggle(ctx);
    }
    fn tray_action(&self) -> Option<&'static str> {
        Some("Start keyboard cleaning")
    }
    fn on_tray_action(&mut self, ctx: &mut Ctx) {
        if self.session.is_none() {
            self.lock(ctx);
        }
    }
    fn update(&mut self, ctx: &mut Ctx) {
        let Some(s) = &self.session else { return };
        let left = remaining_secs(s.deadline, Instant::now());
        if left == 0 || overlay::show(ctx.egui, &s.monitors, left) {
            self.unlock();
        }
    }
    fn shutdown(&mut self) {
        self.unlock();
        blocker::emergency_release();
    }
}

impl Drop for KeyboardCleanFeature {
    fn drop(&mut self) {
        self.unlock();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remaining_rounds_up() {
        let now = Instant::now();
        assert_eq!(remaining_secs(now + Duration::from_millis(59_001), now), 60);
        assert_eq!(remaining_secs(now + Duration::from_secs(60), now), 60);
        assert_eq!(remaining_secs(now + Duration::from_millis(1), now), 1);
    }

    #[test]
    fn remaining_is_zero_past_deadline() {
        let now = Instant::now();
        assert_eq!(remaining_secs(now, now + Duration::from_secs(1)), 0);
        assert_eq!(remaining_secs(now, now), 0);
    }

    #[test]
    fn default_shortcut_is_ctrl_alt_super_k() {
        let f = KeyboardCleanFeature { session: None };
        let s = &f.shortcuts()[0];
        assert_eq!(s.default.key, Code::KeyK);
        assert!(s.default.mods.contains(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SUPER));
    }
}
