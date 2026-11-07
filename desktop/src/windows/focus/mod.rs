//! Focus: one display, one stage. Owns the sets, polls the window list, and
//! moves real windows to match `state`. Port of FocusController.swift.

mod capture;
pub mod layout;
pub mod stage;
pub mod store;
mod ui;

use crate::feature::{Ctx, Feature, Shortcut};
use crate::windows::apps::InstalledApp;
use crate::windows::geometry::Rect;
use crate::windows::platform::{self, GrabMode, Key, KeyEvent, WindowInfo};
use eframe::egui;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use layout::StageLayout;
use stage::{numbers, AddOutcome, PaneDirection, SetLayout, SplitAxis, StageState, WindowId};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use store::Prefs;

const PENDING: Duration = Duration::from_secs(15);

/// The leader was pressed; waiting for one key.
struct Leader {
    armed_at: Instant,
    /// After h/j/k/l the leader stays armed briefly so they can repeat.
    repeat_until: Option<Instant>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum PickMode {
    Replace,
    Split(SplitAxis),
    /// An empty set: the chosen window or app opens on the stage.
    Open,
}

#[derive(Clone, Debug)]
enum PickKind {
    /// A window in another set.
    Window(WindowId),
    /// A window no set holds (floating, overflow, another display).
    Unmanaged(WindowId),
    Installed(InstalledApp),
}

#[derive(Clone, Debug)]
struct PickItem {
    kind: PickKind,
    label: String,
    detail: String,
}

struct Picker {
    mode: PickMode,
    /// Where it sits, in screen pixels.
    rect: Rect,
    /// The window being replaced, or the one the new pane opens beside.
    beside: Option<String>,
    suggestions: Vec<PickItem>,
    searching: bool,
    query: String,
    selection: usize,
}

struct Switcher {
    selection: usize,
    refreshed: Instant,
}

/// The card after a replace (with Undo) or a set change worth a word.
struct Card {
    title: String,
    subtitle: String,
    undo: Option<StageState>,
    until: Instant,
}

type Change = Box<dyn FnOnce(&mut FocusFeature)>;

/// Freeze-and-fade on set switches: a still of the screen covers the
/// change, then fades out.
struct Fade {
    texture: egui::TextureHandle,
    frames: u32,
    pending: Option<Change>,
    started: Option<Instant>,
}

struct Drag {
    last_apply: Instant,
}

pub struct FocusFeature {
    data_dir: PathBuf,
    prefs: Prefs,
    running: bool,
    state: StageState,
    pins: HashMap<String, usize>,
    memory: HashMap<String, usize>,
    homes: HashMap<WindowId, Rect>,
    parked: HashSet<WindowId>,
    /// Floated by the user with the leader's `\`.
    floating: HashSet<WindowId>,
    /// Didn't fit anywhere: every set was full.
    overflow: HashSet<WindowId>,
    /// Minimized windows and the set they come back to.
    away: HashMap<WindowId, usize>,
    own_change_until: HashMap<WindowId, Instant>,
    focus_muted_until: Instant,
    zoomed: Option<WindowId>,
    pending_replace: Option<(WindowId, Instant, StageState)>,
    /// A split opened with v/s whose second pane is still empty.
    open_split: Option<SplitAxis>,
    pending_split: Option<Instant>,
    /// An app we launched recently: its first window gets the stage.
    launched: Option<Instant>,
    settle: Option<(WindowId, Instant)>,
    save_due: Option<Instant>,
    registry: HashMap<WindowId, WindowInfo>,
    /// Front to back.
    order: Vec<WindowId>,
    last_foreground: Option<WindowId>,
    last_poll: Instant,
    /// Physical pixels per logical point.
    scale: f64,
    egui: Option<egui::Context>,
    // UI
    leader: Option<Leader>,
    picker: Option<Picker>,
    switcher: Option<Switcher>,
    shelf: bool,
    edge_since: Option<Instant>,
    card: Option<Card>,
    fade: Option<Fade>,
    drag: Option<Drag>,
    thumbs: HashMap<WindowId, egui::TextureHandle>,
    capturer: capture::Capturer,
    installed: std::sync::Arc<std::sync::Mutex<Option<Vec<InstalledApp>>>>,
    scanning: bool,
}

impl FocusFeature {
    pub fn new() -> Self {
        let data_dir = directories::ProjectDirs::from("com", "giovani", "MacUtility")
            .map(|d| d.data_dir().to_path_buf())
            .unwrap_or_default();
        // A crash (or a kill) left windows parked and Focus won't start this
        // time: bring them back now. When it will start, it takes them over.
        let enabled = crate::settings::Settings::load(&data_dir).enabled.get("focus").copied().unwrap_or(false);
        if !enabled && !data_dir.as_os_str().is_empty() {
            store::recover_if_needed(&data_dir);
        }
        Self {
            prefs: Prefs::load(&data_dir),
            data_dir,
            running: false,
            state: StageState::default(),
            pins: HashMap::new(),
            memory: HashMap::new(),
            homes: HashMap::new(),
            parked: HashSet::new(),
            floating: HashSet::new(),
            overflow: HashSet::new(),
            away: HashMap::new(),
            own_change_until: HashMap::new(),
            focus_muted_until: Instant::now(),
            zoomed: None,
            pending_replace: None,
            open_split: None,
            pending_split: None,
            launched: None,
            settle: None,
            save_due: None,
            registry: HashMap::new(),
            order: Vec::new(),
            last_foreground: None,
            last_poll: Instant::now(),
            scale: 1.0,
            egui: None,
            leader: None,
            picker: None,
            switcher: None,
            shelf: false,
            edge_since: None,
            card: None,
            fade: None,
            drag: None,
            thumbs: HashMap::new(),
            capturer: capture::Capturer::new(),
            installed: Default::default(),
            scanning: false,
        }
    }

    // Lifecycle

    fn start(&mut self, ctx: &mut Ctx) {
        if self.running {
            return;
        }
        if let Err(msg) = platform::supported() {
            log::warn!("focus: {msg}");
            ctx.hud.push(msg);
            return;
        }
        self.data_dir = ctx.data_dir.to_path_buf();
        self.prefs = Prefs::load(&self.data_dir);
        let snap = store::load(&self.data_dir);
        self.state = snap.state;
        self.homes = snap.homes;
        self.parked = snap.parked;
        self.memory = snap.memory;
        self.pins = snap.pins;
        platform::keys_start();
        self.refresh_registry();
        self.last_foreground = platform::foreground();
        self.running = true;
        self.adopt_all();
        self.apply(true);
        log::info!("focus started with {} windows", self.state.all_windows().len());
    }

    /// Brings every parked window back to where it last was on the stage.
    fn stop(&mut self) {
        if !self.running {
            return;
        }
        self.leader = None;
        self.picker = None;
        self.switcher = None;
        self.shelf = false;
        self.drag = None;
        if self.open_split.take().is_some() {
            self.pending_split = None;
            self.apply(false);
        }
        let single = self.layout().single();
        for id in self.state.all_windows() {
            if !self.parked.contains(&id) {
                continue;
            }
            let Some(w) = self.registry.get(&id) else { continue };
            let home = self.homes.get(&id).copied().unwrap_or(Rect::new(single.mid_x() - w.frame.w / 2.0, single.y, w.frame.w, w.frame.h));
            platform::set_frame(id, home);
        }
        self.parked.clear();
        platform::keys_set_mode(GrabMode::Off);
        platform::keys_stop();
        self.running = false;
        self.zoomed = None;
        self.save(false);
        log::info!("focus stopped");
    }

    /// First run, or windows that opened while Focus was off.
    fn adopt_all(&mut self) {
        let windows: Vec<WindowInfo> = self
            .order
            .iter()
            .filter_map(|id| self.registry.get(id))
            .filter(|w| self.is_manageable(w) && (self.state.contains(w.id) || self.is_on_display(w)))
            .cloned()
            .collect();
        let live: HashSet<WindowId> = windows.iter().map(|w| w.id).collect();
        self.state.prune(&live);
        let all: HashSet<WindowId> = self.state.all_windows().into_iter().collect();
        self.parked.retain(|id| all.contains(id));
        let fresh: Vec<&WindowInfo> = windows.iter().filter(|w| !self.state.contains(w.id)).collect();
        if self.state.all_windows().is_empty() {
            let list: Vec<(WindowId, String)> = fresh.iter().map(|w| (w.id, w.app.clone())).collect();
            self.overflow.extend(self.state.adopt(&list));
        } else {
            for w in fresh {
                let pref = self.pins.get(&w.app).copied();
                if self.state.add(w.id, pref, false) == AddOutcome::Unmanaged {
                    self.overflow.insert(w.id);
                }
            }
        }
    }

    // Geometry

    fn display(&self) -> Option<platform::Monitor> {
        platform::primary_monitor()
    }

    fn layout(&self) -> StageLayout {
        let stage = self.display().map(|m| m.work).unwrap_or_default();
        StageLayout { stage, gap: (self.prefs.gap * self.scale).round(), width_cap: (self.prefs.width_cap * self.scale).round() }
    }

    fn is_on_display(&self, w: &WindowInfo) -> bool {
        let Some(display) = self.display() else { return false };
        let (cx, cy) = (w.frame.mid_x(), w.frame.mid_y());
        if display.frame.contains(cx, cy) {
            return true;
        }
        // An app that quit while parked can reopen its window in the parking
        // corner, almost entirely off screen. It still belongs here.
        let on_any = platform::monitors().iter().any(|m| m.frame.contains(cx, cy));
        !on_any && display.frame.intersects(&w.frame)
    }

    fn is_manageable(&self, w: &WindowInfo) -> bool {
        !self.floating.contains(&w.id)
            && !w.minimized
            && !w.fullscreen
            && w.normal
            && w.frame.w >= 200.0 * self.scale
            && w.frame.h >= 150.0 * self.scale
    }

    // Placing windows

    /// Moves real windows to match `state`: the current set on the stage,
    /// everything else parked. `focus` raises the set's focused window.
    fn apply(&mut self, focus: bool) {
        if !self.running {
            return;
        }
        let set = self.state.current_set().clone();
        let frames = self.stage_frames();
        self.focus_muted_until = Instant::now() + Duration::from_millis(500);
        for (&id, &r) in &frames {
            self.place(id, r);
        }
        if focus {
            for &id in frames.keys() {
                if Some(id) != set.focused {
                    platform::activate(id);
                }
            }
            if let Some(f) = set.focused.filter(|f| frames.contains_key(f)) {
                platform::activate(f);
                self.last_foreground = Some(f);
            }
        }
        let upcoming = self.next_frames();
        for id in self.state.all_windows() {
            if !frames.contains_key(&id) {
                self.park(id, upcoming.get(&id).copied());
            }
        }
        self.remember_sets();
        self.schedule_save();
    }

    /// The current set's frames; while a split waits for its second window,
    /// the one window keeps the first pane.
    fn stage_frames(&self) -> HashMap<WindowId, Rect> {
        let set = self.state.current_set();
        let layout = self.layout();
        if let (Some(axis), [only]) = (self.open_split, set.windows.as_slice()) {
            return HashMap::from([(*only, layout.split(set.ratio, axis).0)]);
        }
        layout.frames(set, self.zoomed)
    }

    fn place(&mut self, id: WindowId, r: Rect) {
        let Some(w) = self.registry.get_mut(&id) else { return };
        self.homes.insert(id, r);
        self.parked.remove(&id);
        if w.frame.close_to(&r) {
            return;
        }
        w.frame = r;
        self.own_change_until.insert(id, Instant::now() + Duration::from_millis(800));
        platform::set_frame(id, r);
    }

    /// Where every parked window will sit when its set is next on stage.
    fn next_frames(&self) -> HashMap<WindowId, Rect> {
        let layout = self.layout();
        let mut out = HashMap::new();
        for n in numbers() {
            let set = self.state.set(n);
            for (id, r) in layout.frames(set, None) {
                out.entry(id).or_insert(r);
            }
            // The hidden half of a stacked set comes back at full stage size.
            for &id in &set.windows {
                out.entry(id).or_insert_with(|| layout.single());
            }
        }
        out
    }

    /// Parks a window in the corner, already at the size it will have when
    /// it's next shown, so it comes back without resizing on screen.
    fn park(&mut self, id: WindowId, size: Option<Rect>) {
        let Some(display) = self.display() else { return };
        let others: Vec<Rect> = platform::monitors().into_iter().filter(|m| !m.primary).map(|m| m.frame).collect();
        let Some(w) = self.registry.get_mut(&id) else { return };
        let (tw, th) = size.map(|s| (s.w, s.h)).unwrap_or((w.frame.w, w.frame.h));
        let (ox, oy) = StageLayout::parking_origin(tw, th, &display.frame, &others);
        if !self.parked.contains(&id) && display.frame.intersects(&w.frame) {
            self.homes.insert(id, w.frame);
        }
        self.parked.insert(id);
        let target = Rect::new(ox, oy, tw, th);
        if w.frame.close_to(&target) {
            return;
        }
        w.frame = target;
        self.own_change_until.insert(id, Instant::now() + Duration::from_millis(800));
        platform::set_frame(id, target);
    }

    /// Switch sets behind the fade (or at once with the fade off).
    fn transition(&mut self, change: Change) {
        if self.prefs.fade && self.fade.is_none() {
            if let (Some(ctx), Some(shot)) = (self.egui.clone(), capture::primary_screen()) {
                let img = egui::ColorImage::from_rgba_unmultiplied([shot.w as usize, shot.h as usize], &shot.rgba);
                let texture = ctx.load_texture("focus-fade", img, egui::TextureOptions::LINEAR);
                self.fade = Some(Fade { texture, frames: 0, pending: Some(change), started: None });
                ctx.request_repaint();
                return;
            }
        }
        change(self);
    }

    // Window list polling: stands in for the macOS AX observers.

    fn refresh_registry(&mut self) -> Vec<WindowInfo> {
        let list = platform::windows();
        self.order = list.iter().map(|w| w.id).collect();
        let old = std::mem::take(&mut self.registry);
        self.registry = list.iter().map(|w| (w.id, w.clone())).collect();
        old.into_values().collect()
    }

    fn poll(&mut self) {
        let before: HashMap<WindowId, WindowInfo> = self.refresh_registry().into_iter().map(|w| (w.id, w)).collect();
        let now: Vec<WindowInfo> = self.order.iter().filter_map(|id| self.registry.get(id).cloned()).collect();
        let gone: Vec<WindowId> = before.keys().filter(|id| !self.registry.contains_key(id)).copied().collect();
        for id in gone {
            self.window_gone(id);
        }
        for w in &now {
            match before.get(&w.id) {
                None => {
                    let fresh_app = !before.values().any(|o| o.app == w.app);
                    self.window_appeared(w.id, fresh_app);
                }
                Some(old) => {
                    if !old.minimized && w.minimized {
                        if let Some(n) = self.state.remove(w.id) {
                            self.away.insert(w.id, n);
                            self.apply(n == self.state.current);
                        }
                    } else if old.minimized && !w.minimized {
                        match self.away.remove(&w.id) {
                            Some(n) => self.add(w.id, Some(n), true),
                            None => self.window_appeared(w.id, false),
                        }
                    } else if !old.frame.close_to(&w.frame) {
                        self.user_changed(w.id);
                    }
                }
            }
        }
        let fg = platform::foreground();
        if fg != self.last_foreground {
            self.last_foreground = fg;
            if let Some(id) = fg {
                self.focus_changed(id);
            }
        }
    }

    fn window_appeared(&mut self, id: WindowId, fresh_app: bool) {
        if self.state.contains(id) || self.overflow.contains(&id) {
            return;
        }
        let Some(w) = self.registry.get(&id).cloned() else { return };
        if !self.is_manageable(&w) || !self.is_on_display(&w) {
            return;
        }
        let now = Instant::now();
        if let (Some(until), Some(axis)) = (self.pending_split, self.open_split) {
            if now < until {
                self.pending_split = None;
                self.open_split = None;
                if self.state.pull_in_new(id, axis) {
                    self.apply(true);
                } else {
                    self.add(id, None, true);
                }
                return;
            }
        }
        if let Some((target, until, before)) = self.pending_replace.clone() {
            if now < until && self.state.contains(target) {
                self.pending_replace = None;
                let went = self.state.replace_with_new(target, id);
                if went.is_none() {
                    self.overflow.insert(target);
                }
                self.apply(true);
                self.show_replaced(id, target, went, before);
                return;
            }
        }
        let launched = self.launched.is_some_and(|t| now.duration_since(t) < PENDING);
        if launched {
            self.launched = None;
        }
        let front = platform::foreground() == Some(id) || launched;
        let pref = self.preferred_set(&w, fresh_app);
        self.add(id, pref, front);
    }

    fn add(&mut self, id: WindowId, preferred: Option<usize>, activate: bool) {
        match self.state.add(id, preferred, activate) {
            AddOutcome::JoinedCurrent => self.apply(activate),
            AddOutcome::Placed { number, switched, because_full } => {
                self.apply(switched);
                // Only worth a word when the window didn't land where you were.
                if switched && because_full {
                    let prev = self.state.previous.unwrap_or(number);
                    self.show_card(number, Some(format!("Set {prev} already had two windows. {} Tab goes back.", self.leader_label())));
                }
            }
            AddOutcome::Unmanaged => {
                self.overflow.insert(id);
                self.card_text("Every set is full", "");
            }
        }
    }

    fn window_gone(&mut self, id: WindowId) {
        self.floating.remove(&id);
        self.overflow.remove(&id);
        self.away.remove(&id);
        self.homes.remove(&id);
        self.parked.remove(&id);
        self.own_change_until.remove(&id);
        self.thumbs.remove(&id);
        if self.zoomed == Some(id) {
            self.zoomed = None;
        }
        if self.pending_replace.as_ref().is_some_and(|p| p.0 == id) {
            self.pending_replace = None;
        }
        if let Some(n) = self.state.remove(id) {
            self.apply(n == self.state.current);
        }
    }

    fn focus_changed(&mut self, id: WindowId) {
        if Instant::now() <= self.focus_muted_until || !self.state.contains(id) {
            return;
        }
        if self.state.focus(id) {
            // Alt+Tab or a taskbar click on a parked window: the stage follows it.
            self.zoomed = None;
            self.apply(false);
        } else if self.state.current_set().layout == SetLayout::Stacked {
            self.apply(false);
        } else {
            self.schedule_save();
        }
    }

    /// The user dragged or resized a window, or an app moved its own.
    fn user_changed(&mut self, id: WindowId) {
        if self.own_change_until.get(&id).is_some_and(|&t| Instant::now() < t) {
            return;
        }
        let Some(w) = self.registry.get(&id).cloned() else { return };
        if !self.state.contains(id) {
            // A window arriving on this display, e.g. with Ctrl+Win+Left.
            if !self.overflow.contains(&id) && !self.away.contains_key(&id) {
                self.window_appeared(id, false);
            }
            return;
        }
        if self.parked.contains(&id) {
            return;
        }
        if !self.is_on_display(&w) {
            // Dragged to another display: it leaves its set.
            self.state.remove(id);
            self.apply(false);
            return;
        }
        self.settle = Some((id, Instant::now() + Duration::from_millis(300)));
    }

    /// After a resize stops: a split side's new size becomes the ratio.
    /// Anything else snaps back into place.
    fn settle(&mut self, id: WindowId) {
        let set = self.state.current_set().clone();
        let layout = self.layout();
        if set.windows.len() == 2 && set.layout == SetLayout::Split && self.zoomed.is_none() {
            if let (Some(index), Some(w), Some(expected)) =
                (set.windows.iter().position(|&x| x == id), self.registry.get(&id), layout.frames(&set, None).get(&id).copied())
            {
                if (w.frame.w - expected.w).abs() > 2.0 || (w.frame.h - expected.h).abs() > 2.0 {
                    let r = layout.ratio_for(w.frame.w, w.frame.h, index == 0, set.axis);
                    self.state.set_ratio(r);
                }
            }
        }
        self.apply(false);
    }

    // Commands

    fn go_to(&mut self, number: usize) {
        if !self.running || !numbers().contains(&number) || number == self.state.current {
            return;
        }
        self.transition(Box::new(move |f: &mut FocusFeature| {
            f.zoomed = None;
            f.state.go_to(number);
            f.apply(true);
        }));
    }

    fn back(&mut self) {
        if let Some(p) = self.state.previous {
            self.go_to(p);
        }
    }

    /// Leader Shift+1-9: the focused window moves to that set and you go with it.
    fn send_to(&mut self, number: usize) {
        if !self.running || !numbers().contains(&number) || number == self.state.current {
            return;
        }
        let Some(id) = self.focused_window() else { return };
        self.state.send(id, number);
        self.state.set_mut(number).focused = Some(id);
        self.zoomed = None;
        self.open_split = None;
        self.transition(Box::new(move |f: &mut FocusFeature| {
            f.state.go_to(number);
            f.apply(true);
        }));
    }

    /// Leader v or s. One window: split now, with the picker in the empty
    /// pane. Two: just turn the split that way.
    fn split(&mut self, axis: SplitAxis) {
        let set = self.state.current_set().clone();
        self.zoomed = None;
        if set.windows.len() == 2 {
            self.state.set_axis(axis);
            self.apply(true);
            return;
        }
        let Some(focused) = set.focused.or(set.windows.first().copied()) else {
            self.show_open();
            return;
        };
        self.shelf = false;
        self.state.current_set_mut().ratio = 0.5;
        self.open_split = Some(axis);
        self.pending_split = None;
        self.apply(false);
        let (_, empty) = self.layout().split(0.5, axis);
        let beside = self.name_of(focused);
        self.show_picker(PickMode::Split(axis), empty, Some(beside), false);
    }

    /// Esc in the picker: the window takes the whole stage again.
    fn cancel_split(&mut self) {
        if self.open_split.take().is_some() {
            self.pending_split = None;
            self.apply(true);
        }
    }

    fn toggle_axis(&mut self) {
        if self.state.toggle_axis() {
            self.zoomed = None;
            self.apply(true);
        }
    }

    /// Leader o, like vim's Ctrl-w o: keep the focused window alone.
    fn only(&mut self) {
        let Some(other) = self.state.current_set().unfocused() else { return };
        let name = self.name_of(other);
        let Some(went) = self.state.only() else {
            self.card_text(&format!("No free set for {name}"), "");
            return;
        };
        self.zoomed = None;
        self.apply(true);
        self.show_card(went, Some(format!("{name} moved to set {went}")));
    }

    /// Our record of the focused pane can drift from the real one, so take
    /// the real one before acting on it.
    fn sync_focus(&mut self) {
        if let Some(actual) = platform::foreground() {
            if self.state.current_set().windows.contains(&actual) {
                self.state.current_set_mut().focused = Some(actual);
            }
        }
    }

    fn focus_pane(&mut self, d: PaneDirection) {
        self.sync_focus();
        if self.state.current_set().layout == SetLayout::Stacked {
            if self.state.current_set().windows.len() == 2 {
                self.state.focus_other();
                self.zoomed = None;
                self.apply(true);
            }
            return;
        }
        if self.state.focus_pane(d) {
            self.zoomed = None;
            self.apply(true);
        } else if let Some(f) = self.state.current_set().focused {
            if platform::foreground() != Some(f) {
                platform::activate(f);
            }
        }
    }

    fn swap_windows(&mut self) {
        self.state.swap_order();
        self.apply(true);
    }

    fn toggle_layout(&mut self) {
        if self.state.current_set().windows.len() == 2 {
            self.state.toggle_layout();
            self.zoomed = None;
            self.apply(true);
        }
    }

    fn toggle_zoom(&mut self) {
        let Some(id) = self.focused_window() else { return };
        self.zoomed = if self.zoomed == Some(id) { None } else { Some(id) };
        self.apply(true);
    }

    fn toggle_float(&mut self) {
        let Some(id) = platform::foreground() else { return };
        if self.state.contains(id) {
            self.state.remove(id);
            self.floating.insert(id);
            self.apply(false);
            platform::activate(id);
            self.card_text("Floating", "");
        } else if self.floating.remove(&id) {
            self.window_appeared(id, false);
            self.card_text("Tiled", "");
        }
    }

    /// The managed window that has focus, or the current set's focused one.
    fn focused_window(&self) -> Option<WindowId> {
        platform::foreground()
            .filter(|id| self.state.current_set().windows.contains(id))
            .or(self.state.current_set().focused)
    }

    fn replace_with(&mut self, other: WindowId) {
        let Some(target) = self.focused_window() else { return };
        if target == other {
            return;
        }
        let before = self.state.clone();
        let Some(went) = self.state.replace(target, other) else { return };
        self.zoomed = None;
        self.apply(true);
        self.show_replaced(other, target, Some(went), before);
    }

    /// A window no set holds takes the focused window's place.
    fn replace_with_unmanaged(&mut self, id: WindowId) {
        let Some(target) = self.focused_window() else { return };
        let before = self.state.clone();
        self.floating.remove(&id);
        self.overflow.remove(&id);
        let went = self.state.replace_with_new(target, id);
        if went.is_none() {
            self.overflow.insert(target);
        }
        self.zoomed = None;
        self.apply(true);
        self.show_replaced(id, target, went, before);
    }

    fn undo(&mut self, before: StageState) {
        let mut restored = before;
        let live: HashSet<WindowId> = self.registry.keys().copied().collect();
        restored.prune(&live);
        for id in self.state.all_windows() {
            if !restored.contains(id) {
                restored.add(id, None, false);
            }
        }
        self.state = restored;
        self.apply(true);
        self.card_text("Undone", "");
    }

    fn toggle_pin(&mut self, app: &str, number: usize) {
        if self.pins.get(app) == Some(&number) {
            self.pins.remove(app);
        } else {
            self.pins.insert(app.to_string(), number);
        }
        self.schedule_save();
    }

    fn open_window(&mut self, id: WindowId) {
        if !self.state.current_set().has_room() {
            return;
        }
        match self.state.set_number(id) {
            Some(from) if from != self.state.current => {
                self.state.remove(id);
            }
            Some(_) => return,
            None => {
                self.floating.remove(&id);
                self.overflow.remove(&id);
            }
        }
        let s = self.state.current_set_mut();
        s.insert(id);
        s.focused = Some(id);
        self.apply(true);
    }

    fn choose(&mut self, mode: PickMode, item: PickItem) {
        self.picker = None;
        match (mode, item.kind) {
            (PickMode::Replace, PickKind::Window(id)) => self.replace_with(id),
            (PickMode::Replace, PickKind::Unmanaged(id)) => self.replace_with_unmanaged(id),
            (PickMode::Replace, PickKind::Installed(app)) => {
                if let Some(target) = self.focused_window() {
                    self.pending_replace = Some((target, Instant::now() + PENDING, self.state.clone()));
                    platform::launch(&app.path);
                }
            }
            (PickMode::Split(axis), PickKind::Window(id)) => {
                self.open_split = None;
                self.state.pull_in(id, axis);
                self.apply(true);
            }
            (PickMode::Split(axis), PickKind::Unmanaged(id)) => {
                self.open_split = None;
                self.floating.remove(&id);
                self.overflow.remove(&id);
                self.state.pull_in_new(id, axis);
                self.apply(true);
            }
            (PickMode::Split(_), PickKind::Installed(app)) => {
                self.pending_split = Some(Instant::now() + PENDING);
                platform::launch(&app.path);
            }
            (PickMode::Open, PickKind::Window(id) | PickKind::Unmanaged(id)) => self.open_window(id),
            (PickMode::Open, PickKind::Installed(app)) => {
                self.launched = Some(Instant::now());
                platform::launch(&app.path);
            }
        }
    }

    fn cancel_picker(&mut self) {
        if let Some(p) = self.picker.take() {
            if matches!(p.mode, PickMode::Split(_)) {
                self.cancel_split();
            }
        }
    }

    // Panels

    fn show_replace(&mut self) {
        let Some(target) = self.focused_window() else {
            self.show_open();
            return;
        };
        self.shelf = false;
        let layout = self.layout();
        let frame = layout.frames(self.state.current_set(), self.zoomed).get(&target).copied().unwrap_or(layout.single());
        let name = self.name_of(target);
        self.show_picker(PickMode::Replace, frame, Some(name), false);
    }

    /// An empty set: the picker over the whole stage, search ready.
    fn show_open(&mut self) {
        self.shelf = false;
        let inner = self.layout().inner();
        self.show_picker(PickMode::Open, inner, None, true);
    }

    fn show_picker(&mut self, mode: PickMode, rect: Rect, beside: Option<String>, search: bool) {
        self.load_installed();
        let suggestions = self.suggestions();
        self.picker = Some(Picker { mode, rect, beside, suggestions, searching: search, query: String::new(), selection: 0 });
    }

    fn show_switcher(&mut self) {
        if self.switcher.take().is_some() {
            return;
        }
        self.shelf = false;
        self.capturer.request(self.state.all_windows());
        self.switcher = Some(Switcher { selection: self.state.current, refreshed: Instant::now() });
    }

    fn load_installed(&mut self) {
        if self.scanning {
            return;
        }
        self.scanning = true;
        let slot = self.installed.clone();
        let _ = std::thread::Builder::new().name("focus-apps".into()).spawn(move || {
            let apps = crate::windows::apps::scan();
            if let Ok(mut s) = slot.lock() {
                *s = Some(apps);
            }
        });
    }

    /// Windows parked in other sets, then one window per app that no set holds.
    fn suggestions(&self) -> Vec<PickItem> {
        let mut out = Vec::new();
        for n in numbers().filter(|&n| n != self.state.current) {
            for &id in &self.state.set(n).windows {
                let (label, title) = self.registry.get(&id).map(|w| (w.app_name.clone(), w.title.clone())).unwrap_or_default();
                out.push(PickItem { kind: PickKind::Window(id), label, detail: format!("Set {n} · {title}") });
            }
        }
        let mut seen = HashSet::new();
        let mut apps: Vec<PickItem> = Vec::new();
        for id in &self.order {
            let Some(w) = self.registry.get(id) else { continue };
            if self.state.contains(w.id) || w.minimized || !w.normal || !seen.insert(w.app.clone()) {
                continue;
            }
            apps.push(PickItem { kind: PickKind::Unmanaged(w.id), label: w.app_name.clone(), detail: w.title.clone() });
        }
        apps.sort_by_key(|i| i.label.to_lowercase());
        out.extend(apps);
        out
    }

    fn picker_items(&self, p: &Picker) -> Vec<PickItem> {
        let q = p.query.trim().to_lowercase();
        if !p.searching || q.is_empty() {
            return p.suggestions.clone();
        }
        let mut out: Vec<PickItem> = p
            .suggestions
            .iter()
            .filter(|i| format!("{} {}", i.label, i.detail).to_lowercase().contains(&q))
            .cloned()
            .collect();
        if let Ok(guard) = self.installed.lock() {
            if let Some(apps) = guard.as_ref() {
                for a in crate::windows::apps::search(apps, &q) {
                    out.push(PickItem { kind: PickKind::Installed(a.clone()), label: a.name.clone(), detail: "Open".into() });
                }
            }
        }
        out
    }

    fn card_text(&mut self, title: &str, subtitle: &str) {
        self.card = Some(Card { title: title.into(), subtitle: subtitle.into(), undo: None, until: Instant::now() + Duration::from_millis(1800) });
    }

    fn show_card(&mut self, number: usize, message: Option<String>) {
        let (name, apps) = self.set_names(number);
        let title = format!("{number} · {name}");
        self.card = Some(Card { title, subtitle: message.unwrap_or(apps), undo: None, until: Instant::now() + Duration::from_millis(2500) });
    }

    fn show_replaced(&mut self, id: WindowId, replaced: WindowId, went: Option<usize>, before: StageState) {
        let replaced_name = self.name_of(replaced);
        let subtitle = match went {
            Some(n) => format!("{replaced_name} moved to set {n}"),
            None => format!("Every set was full, so {replaced_name} floats"),
        };
        self.card = Some(Card {
            title: format!("{} is here", self.name_of(id)),
            subtitle,
            undo: Some(before),
            until: Instant::now() + Duration::from_secs(5),
        });
    }

    fn name_of(&self, id: WindowId) -> String {
        self.registry.get(&id).map(|w| w.app_name.clone()).unwrap_or_else(|| "Window".into())
    }

    /// The set's name (its first app) and every app in it.
    fn set_names(&self, n: usize) -> (String, String) {
        let names: Vec<String> = self.state.set(n).windows.iter().map(|&id| self.name_of(id)).collect();
        (names.first().cloned().unwrap_or_else(|| format!("Set {n}")), names.join(" · "))
    }

    // Leader key

    fn leader_hotkey(&self) -> HotKey {
        crate::settings::Settings::load(&self.data_dir).shortcuts.get("focus.leader").copied().unwrap_or_else(default_leader)
    }

    fn leader_label(&self) -> String {
        crate::shortcut_label::label(&self.leader_hotkey())
    }

    fn arm_leader(&mut self) {
        if self.leader.is_some() {
            // Leader twice: hand the leader to the app, like tmux's prefix-prefix.
            self.disarm();
            self.pass_through();
            return;
        }
        self.leader = Some(Leader { armed_at: Instant::now(), repeat_until: None });
        platform::keys_set_mode(GrabMode::Grab);
    }

    fn disarm(&mut self) {
        if self.leader.take().is_some() && self.switcher.is_none() {
            self.shelf = false;
        }
    }

    fn pass_through(&self) {
        let hk = self.leader_hotkey();
        if let Some(c) = code_char(hk.key) {
            platform::pass_through(c, hk.mods.contains(Modifiers::CONTROL), hk.mods.contains(Modifiers::SHIFT), hk.mods.contains(Modifiers::ALT));
        }
    }

    fn is_leader(&self, k: &KeyEvent) -> bool {
        let hk = self.leader_hotkey();
        code_char(hk.key).is_some_and(|c| k.key == Key::Char(c))
            && k.ctrl == hk.mods.contains(Modifiers::CONTROL)
            && k.alt == hk.mods.contains(Modifiers::ALT)
            && k.shift == hk.mods.contains(Modifiers::SHIFT)
    }

    fn leader_key(&mut self, k: KeyEvent) {
        if self.is_leader(&k) {
            self.disarm();
            self.pass_through();
            return;
        }
        let pane = |f: &mut Self, d: PaneDirection| {
            if k.shift {
                f.swap_windows();
            } else {
                f.focus_pane(d);
            }
            // Stay armed briefly so the arrows can repeat.
            if let Some(l) = f.leader.as_mut() {
                l.repeat_until = Some(Instant::now() + Duration::from_millis(600));
            }
        };
        if let Key::Char(c @ '1'..='9') = k.key {
            self.disarm();
            let n = c as usize - '0' as usize;
            if k.shift {
                self.send_to(n)
            } else {
                self.go_to(n)
            }
            return;
        }
        match k.key {
            Key::Left | Key::Char('h') => return pane(self, PaneDirection::Left),
            Key::Down | Key::Char('j') => return pane(self, PaneDirection::Down),
            Key::Up | Key::Char('k') => return pane(self, PaneDirection::Up),
            Key::Right | Key::Char('l') => return pane(self, PaneDirection::Right),
            _ => {}
        }
        self.disarm();
        match k.key {
            Key::Tab => self.back(),
            Key::Enter => self.toggle_layout(),
            Key::Space => self.show_switcher(),
            Key::Char('v') => self.split(SplitAxis::Vertical),
            Key::Char('s') => self.split(SplitAxis::Horizontal),
            Key::Char('o') => self.only(),
            Key::Char('t') => self.toggle_axis(),
            Key::Char('r') => self.show_replace(),
            Key::Char('f') => self.toggle_zoom(),
            Key::Char('\\') => self.toggle_float(),
            // Unbound keys and Esc close the guide and never reach the app.
            _ => {}
        }
    }

    /// Browsing: j/k or arrows move, `/` searches, Return chooses, Esc
    /// cancels. Searching: type to filter, arrows move, Return chooses, Esc
    /// clears the search, then leaves it.
    fn picker_key(&mut self, k: KeyEvent) {
        let Some(p) = self.picker.as_ref() else { return };
        if k.ctrl || k.alt {
            return;
        }
        let items = self.picker_items(p);
        let Some(p) = self.picker.as_mut() else { return };
        let count = items.len();
        let step = |p: &mut Picker, d: isize| {
            if count > 0 {
                p.selection = (p.selection as isize + d).clamp(0, count as isize - 1) as usize;
            }
        };
        match k.key {
            Key::Escape => {
                if p.searching && !p.query.is_empty() {
                    p.query.clear();
                } else if p.searching && p.mode != PickMode::Open {
                    p.searching = false;
                } else {
                    self.cancel_picker();
                }
            }
            Key::Down => step(p, 1),
            Key::Up => step(p, -1),
            Key::Enter => {
                if let Some(item) = items.get(p.selection).cloned() {
                    let mode = p.mode;
                    self.choose(mode, item);
                }
            }
            _ if p.searching => match k.key {
                Key::Backspace => {
                    p.query.pop();
                    p.selection = 0;
                }
                Key::Space => p.query.push(' '),
                Key::Char(c) => {
                    p.query.push(if k.shift { c.to_ascii_uppercase() } else { c });
                    p.selection = 0;
                }
                _ => {}
            },
            Key::Char('j') => step(p, 1),
            Key::Char('k') => step(p, -1),
            Key::Char('/') => {
                p.searching = true;
                p.selection = 0;
            }
            _ => {}
        }
    }

    /// h/j/k/l or arrows move, Return goes, 1-9 jump, Esc (or Space) closes.
    fn switcher_key(&mut self, k: KeyEvent) {
        let Some(s) = self.switcher.as_mut() else { return };
        let (col, row) = ((s.selection - 1) % 3, (s.selection - 1) / 3);
        let mv = |c: isize, r: isize| -> usize { ((row as isize + r).clamp(0, 2) * 3 + (col as isize + c).clamp(0, 2) + 1) as usize };
        match k.key {
            Key::Escape | Key::Space => self.switcher = None,
            Key::Enter => {
                let n = s.selection;
                self.switcher = None;
                self.go_to(n);
            }
            Key::Char(c @ '1'..='9') => {
                self.switcher = None;
                self.go_to(c as usize - '0' as usize);
            }
            Key::Left | Key::Char('h') => s.selection = mv(-1, 0),
            Key::Right | Key::Char('l') => s.selection = mv(1, 0),
            Key::Up | Key::Char('k') => s.selection = mv(0, -1),
            Key::Down | Key::Char('j') => s.selection = mv(0, 1),
            _ => {}
        }
    }

    // Memory and saving

    fn preferred_set(&self, w: &WindowInfo, fresh_app: bool) -> Option<usize> {
        if let Some(&p) = self.pins.get(&w.app) {
            return Some(p);
        }
        // Only for apps relaunching: restore where their windows were.
        if !fresh_app {
            return None;
        }
        self.memory.get(&format!("{}\t{}", w.app, w.title)).or(self.memory.get(&w.app)).copied()
    }

    fn remember_sets(&mut self) {
        for n in numbers() {
            for &id in &self.state.set(n).windows {
                if let Some(w) = self.registry.get(&id) {
                    self.memory.insert(format!("{}\t{}", w.app, w.title), n);
                    self.memory.insert(w.app.clone(), n);
                }
            }
        }
    }

    fn schedule_save(&mut self) {
        self.save_due = Some(Instant::now() + Duration::from_millis(300));
    }

    fn save(&mut self, active: bool) {
        self.save_due = None;
        // Bound the memory so it can't grow forever.
        if self.memory.len() > 500 {
            self.memory.retain(|k, _| !k.contains('\t'));
        }
        let snap = store::Snapshot {
            state: self.state.clone(),
            homes: self.homes.iter().filter(|(id, _)| self.state.contains(**id)).map(|(k, v)| (*k, *v)).collect(),
            parked: self.parked.clone(),
            memory: self.memory.clone(),
            pins: self.pins.clone(),
            active,
        };
        store::save(&self.data_dir, &snap);
    }

    /// Timers, polling and key routing; runs every frame.
    fn tick(&mut self) {
        let now = Instant::now();
        let fast = !self.order.is_empty() && now.duration_since(self.last_poll) >= Duration::from_millis(250);
        if platform::take_dirty() || fast || now.duration_since(self.last_poll) >= Duration::from_millis(500) {
            self.last_poll = now;
            self.poll();
        }
        if let Some((id, at)) = self.settle {
            if now >= at {
                self.settle = None;
                self.settle(id);
            }
        }
        if self.pending_split.is_some_and(|t| now >= t) {
            // No window came: give the stage back to the one that's there.
            self.pending_split = None;
            self.cancel_split();
        }
        if self.pending_replace.as_ref().is_some_and(|p| now >= p.1) {
            self.pending_replace = None;
        }
        // Nothing tells us when the user clicks away, so a forgotten leader expires.
        let expired = self.leader.as_ref().is_some_and(|l| l.repeat_until.is_none() && now.duration_since(l.armed_at) > Duration::from_secs(8));
        if expired || self.leader.as_ref().and_then(|l| l.repeat_until).is_some_and(|t| now >= t) {
            self.disarm();
        }
        for k in platform::keys_poll() {
            if self.picker.is_some() {
                self.picker_key(k);
            } else if self.switcher.is_some() {
                self.switcher_key(k);
            } else if self.leader.is_some() {
                self.leader_key(k);
            }
        }
        let grab = self.leader.is_some() || self.picker.is_some() || self.switcher.is_some();
        platform::keys_set_mode(if grab { GrabMode::Grab } else { GrabMode::Off });
        if self.save_due.is_some_and(|t| now >= t) {
            self.save(true);
        }
    }
}

fn default_leader() -> HotKey {
    HotKey::new(Some(Modifiers::CONTROL), Code::KeyB)
}

/// The character a letter or digit key types, unshifted.
fn code_char(code: Code) -> Option<char> {
    let name = format!("{code:?}");
    let c = name.strip_prefix("Key").or_else(|| name.strip_prefix("Digit"))?;
    let mut chars = c.chars();
    let ch = chars.next()?;
    chars.next().is_none().then(|| ch.to_ascii_lowercase())
}

impl Feature for FocusFeature {
    fn id(&self) -> &'static str {
        "focus"
    }
    fn title(&self) -> &'static str {
        "Focus window manager"
    }
    fn enabled_by_default(&self) -> bool {
        false
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        vec![Shortcut { id: "leader", label: "Focus prefix, then one key", default: default_leader() }]
    }
    fn set_enabled(&mut self, on: bool, ctx: &mut Ctx) {
        self.egui = Some(ctx.egui.clone());
        self.scale = ctx.egui.pixels_per_point() as f64;
        if on {
            self.start(ctx);
        } else {
            self.stop();
            store::recover_if_needed(ctx.data_dir);
        }
    }
    fn on_shortcut(&mut self, id: &str, _ctx: &mut Ctx) {
        if id == "leader" && self.running {
            if self.switcher.is_some() || self.picker.is_some() {
                return;
            }
            self.arm_leader();
        }
    }
    fn update(&mut self, ctx: &mut Ctx) {
        if !self.running {
            return;
        }
        self.egui = Some(ctx.egui.clone());
        self.scale = ctx.egui.pixels_per_point() as f64;
        self.tick();
        if self.running {
            self.draw(ctx.egui);
        }
    }
    fn settings_ui(&mut self, ui: &mut egui::Ui, _ctx: &mut Ctx) {
        let mut p = self.prefs.clone();
        ui.horizontal(|ui| {
            ui.label("Lone window max width");
            ui.add(egui::Slider::new(&mut p.width_cap, 800.0..=3840.0).step_by(10.0).suffix(" pt"));
        });
        ui.horizontal(|ui| {
            ui.label("Gap between windows");
            ui.add(egui::Slider::new(&mut p.gap, 0.0..=40.0).step_by(1.0).suffix(" pt"));
        });
        ui.checkbox(&mut p.fade, "Fade when switching sets");
        if p != self.prefs {
            p.save(&self.data_dir);
            self.prefs = p;
            self.apply(false);
        }
    }
    fn shutdown(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_char_maps_letters_and_digits() {
        assert_eq!(code_char(Code::KeyB), Some('b'));
        assert_eq!(code_char(Code::Digit3), Some('3'));
        assert_eq!(code_char(Code::ArrowLeft), None);
    }

    #[test]
    fn geometry_helpers_link() {
        // The fallback home for a parked window without one is centered on the stage.
        let r = crate::windows::geometry::center(&Rect::new(0.0, 0.0, 100.0, 100.0), &Rect::new(0.0, 0.0, 300.0, 300.0));
        assert_eq!(r, Rect::new(100.0, 100.0, 100.0, 100.0));
    }
}
