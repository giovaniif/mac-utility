//! The nine sets and which one is on the stage. Pure value types: every rule
//! from the Focus spec lives here so it can be tested without a window system.
//! Port of StageState.swift.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

pub type WindowId = u32;

pub const SET_COUNT: usize = 9;
pub const MAX_PER_SET: usize = 2;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SetLayout {
    #[default]
    Split,
    Stacked,
}

/// How a split set divides the stage, named after vim's splits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SplitAxis {
    /// Side by side, like `:vsplit`.
    #[default]
    Vertical,
    /// Top and bottom, like `:split`.
    Horizontal,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneDirection {
    Left,
    Down,
    Up,
    Right,
}

fn half() -> f64 {
    0.5
}

/// Up to two windows shown together on the stage.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FocusSet {
    pub windows: Vec<WindowId>,
    #[serde(default)]
    pub focused: Option<WindowId>,
    #[serde(default)]
    pub layout: SetLayout,
    #[serde(default = "half")]
    pub ratio: f64,
    // Sets saved before `axis` existed decode as side by side.
    #[serde(default)]
    pub axis: SplitAxis,
}

impl Default for FocusSet {
    fn default() -> Self {
        Self { windows: Vec::new(), focused: None, layout: SetLayout::Split, ratio: 0.5, axis: SplitAxis::Vertical }
    }
}

impl FocusSet {
    pub fn is_empty(&self) -> bool {
        self.windows.is_empty()
    }
    pub fn has_room(&self) -> bool {
        self.windows.len() < MAX_PER_SET
    }
    /// The window that isn't focused, when there are two.
    pub fn unfocused(&self) -> Option<WindowId> {
        if self.windows.len() == 2 {
            self.windows.iter().copied().find(|&w| Some(w) != self.focused)
        } else {
            None
        }
    }
    /// Removes a window, moving focus to the one left. Returns its index.
    pub fn remove(&mut self, id: WindowId) -> Option<usize> {
        let index = self.windows.iter().position(|&w| w == id)?;
        self.windows.remove(index);
        if self.focused == Some(id) {
            self.focused = self.windows.first().copied();
        }
        if self.windows.is_empty() {
            self.layout = SetLayout::Split;
        }
        Some(index)
    }
    pub fn insert(&mut self, id: WindowId) {
        self.insert_at(id, None)
    }
    pub fn insert_at(&mut self, id: WindowId, index: Option<usize>) {
        if self.windows.contains(&id) {
            return;
        }
        let at = index.unwrap_or(self.windows.len()).min(self.windows.len());
        self.windows.insert(at, id);
        if self.focused.is_none() {
            self.focused = Some(id);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddOutcome {
    /// Joined the set on the stage.
    JoinedCurrent,
    /// Went to another set; `switched` when the stage followed it.
    Placed { number: usize, switched: bool, because_full: bool },
    /// Every set is full: the window stays unmanaged.
    Unmanaged,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StageState {
    pub sets: Vec<FocusSet>,
    pub current: usize,
    #[serde(default)]
    pub previous: Option<usize>,
}

impl Default for StageState {
    fn default() -> Self {
        Self { sets: vec![FocusSet::default(); SET_COUNT], current: 1, previous: None }
    }
}

pub fn numbers() -> std::ops::RangeInclusive<usize> {
    1..=SET_COUNT
}

fn valid(number: usize) -> bool {
    numbers().contains(&number)
}

impl StageState {
    /// Fixes up a decoded state so indexing can't panic.
    pub fn sanitized(mut self) -> Self {
        self.sets.resize(SET_COUNT, FocusSet::default());
        if !valid(self.current) {
            self.current = 1;
        }
        if self.previous.is_some_and(|p| !valid(p)) {
            self.previous = None;
        }
        self
    }

    pub fn set(&self, number: usize) -> &FocusSet {
        &self.sets[number - 1]
    }
    pub fn set_mut(&mut self, number: usize) -> &mut FocusSet {
        &mut self.sets[number - 1]
    }
    pub fn current_set(&self) -> &FocusSet {
        self.set(self.current)
    }
    pub fn current_set_mut(&mut self) -> &mut FocusSet {
        let c = self.current;
        self.set_mut(c)
    }

    pub fn all_windows(&self) -> Vec<WindowId> {
        self.sets.iter().flat_map(|s| s.windows.iter().copied()).collect()
    }
    pub fn occupied(&self) -> Vec<usize> {
        numbers().filter(|&n| !self.set(n).is_empty()).collect()
    }
    pub fn set_number(&self, id: WindowId) -> Option<usize> {
        numbers().find(|&n| self.set(n).windows.contains(&id))
    }
    pub fn contains(&self, id: WindowId) -> bool {
        self.set_number(id).is_some()
    }
    pub fn lowest_empty(&self, excluding: Option<usize>) -> Option<usize> {
        numbers().find(|&n| Some(n) != excluding && self.set(n).is_empty())
    }
    pub fn lowest_with_room(&self, excluding: Option<usize>) -> Option<usize> {
        numbers().find(|&n| Some(n) != excluding && self.set(n).has_room())
    }

    // Navigation

    pub fn go_to(&mut self, number: usize) {
        if !valid(number) || number == self.current {
            return;
        }
        self.previous = Some(self.current);
        self.current = number;
    }

    // The controller goes through go_to so the switch fades.
    #[allow(dead_code)]
    pub fn back(&mut self) {
        if let Some(p) = self.previous {
            self.go_to(p);
        }
    }

    // Adding and removing

    /// The new-window rule. `preferred` is a pinned or remembered set;
    /// `activate` says the user is looking at this window, so the stage follows it.
    pub fn add(&mut self, id: WindowId, preferred: Option<usize>, activate: bool) -> AddOutcome {
        if let Some(existing) = self.set_number(id) {
            return if existing == self.current {
                AddOutcome::JoinedCurrent
            } else {
                AddOutcome::Placed { number: existing, switched: false, because_full: false }
            };
        }
        if let Some(p) = preferred {
            if valid(p) && self.set(p).has_room() {
                return self.place(id, p, activate, false);
            }
        }
        if self.current_set().has_room() {
            let c = self.current;
            return self.place(id, c, activate, false);
        }
        if let Some(n) = self.lowest_empty(None).or_else(|| self.lowest_with_room(None)) {
            return self.place(id, n, activate, true);
        }
        AddOutcome::Unmanaged
    }

    fn place(&mut self, id: WindowId, number: usize, activate: bool, because_full: bool) -> AddOutcome {
        self.set_mut(number).insert(id);
        if activate {
            self.set_mut(number).focused = Some(id);
        }
        if number == self.current {
            return AddOutcome::JoinedCurrent;
        }
        if activate {
            self.go_to(number);
        }
        AddOutcome::Placed { number, switched: activate, because_full }
    }

    /// Removes a window from its set. An emptied set keeps its number and the
    /// stage stays where it is. Returns the set it was in.
    pub fn remove(&mut self, id: WindowId) -> Option<usize> {
        let n = self.set_number(id)?;
        self.set_mut(n).remove(id);
        Some(n)
    }

    /// Drops windows that no longer exist.
    pub fn prune(&mut self, live: &HashSet<WindowId>) {
        for id in self.all_windows() {
            if !live.contains(&id) {
                self.remove(id);
            }
        }
    }

    /// First start: the frontmost window gets set 1 to itself; then each app
    /// gets the next empty set, up to two windows each, front to back.
    /// Returns the windows that didn't fit.
    pub fn adopt(&mut self, windows: &[(WindowId, String)]) -> Vec<WindowId> {
        let mut app_set: std::collections::HashMap<String, usize> = Default::default();
        let mut left_over = Vec::new();
        for (index, (id, app)) in windows.iter().enumerate() {
            let id = *id;
            if self.contains(id) {
                continue;
            }
            if index == 0 {
                if let Some(n) = self.lowest_empty(None) {
                    self.set_mut(n).insert(id);
                    self.current = n;
                    // The first window has its set to itself.
                    continue;
                }
            }
            match app_set.get(app).copied() {
                Some(n) if self.set(n).has_room() && n != self.current => self.set_mut(n).insert(id),
                _ => {
                    if let Some(n) = self.lowest_empty(None) {
                        self.set_mut(n).insert(id);
                        app_set.insert(app.clone(), n);
                    } else {
                        left_over.push(id);
                    }
                }
            }
        }
        left_over
    }

    // Within a set

    /// Focus moved to this window. If it sits in another set, the stage
    /// follows. Returns true when the set changed.
    pub fn focus(&mut self, id: WindowId) -> bool {
        let Some(n) = self.set_number(id) else { return false };
        self.set_mut(n).focused = Some(id);
        if n == self.current {
            return false;
        }
        self.go_to(n);
        true
    }

    pub fn focus_other(&mut self) {
        if let Some(o) = self.current_set().unfocused() {
            self.current_set_mut().focused = Some(o);
        }
    }

    pub fn swap_order(&mut self) {
        if self.current_set().windows.len() == 2 {
            self.current_set_mut().windows.reverse();
        }
    }

    pub fn toggle_layout(&mut self) {
        if self.current_set().windows.len() != 2 {
            return;
        }
        let s = self.current_set_mut();
        s.layout = if s.layout == SetLayout::Split { SetLayout::Stacked } else { SetLayout::Split };
    }

    /// `v`/`s` on a full set: side by side or top and bottom, shown split.
    pub fn set_axis(&mut self, axis: SplitAxis) {
        let s = self.current_set_mut();
        s.axis = axis;
        s.layout = SetLayout::Split;
    }

    /// Flip a split between side by side and top and bottom. A stacked set
    /// comes back split. Returns false when there's nothing to flip.
    pub fn toggle_axis(&mut self) -> bool {
        let s = self.current_set();
        if s.windows.len() != 2 {
            return false;
        }
        let axis = if s.layout == SetLayout::Stacked {
            s.axis
        } else if s.axis == SplitAxis::Vertical {
            SplitAxis::Horizontal
        } else {
            SplitAxis::Vertical
        };
        self.set_axis(axis);
        true
    }

    /// Focus the pane in a direction, like vim's Ctrl-w h/j/k/l. Returns
    /// false when there's no pane that way.
    pub fn focus_pane(&mut self, direction: PaneDirection) -> bool {
        let s = self.current_set();
        if s.windows.len() != 2 || s.layout != SetLayout::Split {
            return false;
        }
        use PaneDirection::*;
        let target = match (s.axis, direction) {
            (SplitAxis::Vertical, Left) | (SplitAxis::Horizontal, Up) => Some(s.windows[0]),
            (SplitAxis::Vertical, Right) | (SplitAxis::Horizontal, Down) => Some(s.windows[1]),
            _ => None,
        };
        match target {
            Some(t) if Some(t) != s.focused => {
                self.current_set_mut().focused = Some(t);
                true
            }
            _ => false,
        }
    }

    /// Split: bring a window from another set into the current one, beside
    /// the focused window. Returns the set it came from.
    pub fn pull_in(&mut self, id: WindowId, axis: SplitAxis) -> Option<usize> {
        if !self.current_set().has_room() {
            return None;
        }
        let from = self.set_number(id)?;
        if from == self.current {
            return None;
        }
        self.set_mut(from).remove(id);
        let s = self.current_set_mut();
        s.insert(id);
        s.focused = Some(id);
        s.axis = axis;
        s.layout = SetLayout::Split;
        Some(from)
    }

    /// Split with a window that isn't managed yet.
    pub fn pull_in_new(&mut self, id: WindowId, axis: SplitAxis) -> bool {
        if !self.current_set().has_room() || self.contains(id) {
            return false;
        }
        let s = self.current_set_mut();
        s.insert(id);
        s.focused = Some(id);
        s.axis = axis;
        s.layout = SetLayout::Split;
        true
    }

    /// Only, like vim's Ctrl-w o: keep the focused window, move the other to
    /// a new set. Returns where it went, or None when nothing moved.
    pub fn only(&mut self) -> Option<usize> {
        let other = self.current_set().unfocused()?;
        let c = Some(self.current);
        let target = self.lowest_empty(c).or_else(|| self.lowest_with_room(c))?;
        self.current_set_mut().remove(other);
        self.set_mut(target).insert(other);
        Some(target)
    }

    pub fn set_ratio(&mut self, ratio: f64) {
        self.current_set_mut().ratio = snap(ratio);
    }

    // Moving between sets

    /// Send a window to set `number`. Joins it when there's room, otherwise
    /// swaps with that set's unfocused window. The stage stays put.
    pub fn send(&mut self, id: WindowId, number: usize) {
        if !valid(number) {
            return;
        }
        let Some(from) = self.set_number(id) else { return };
        if from == number {
            return;
        }
        if self.set(number).has_room() {
            self.set_mut(from).remove(id);
            self.set_mut(number).insert(id);
            return;
        }
        let target = self.set(number);
        let Some(out) = target.unfocused().or_else(|| target.windows.last().copied()) else { return };
        let Some(out_index) = target.windows.iter().position(|&w| w == out) else { return };
        let from_index = self.set_mut(from).remove(id);
        self.set_mut(number).windows[out_index] = id;
        self.set_mut(from).insert_at(out, from_index);
    }

    /// Replace: `focused` and `other` (in another set) trade places. Returns
    /// the set the replaced window went to.
    pub fn replace(&mut self, focused: WindowId, other: WindowId) -> Option<usize> {
        let a = self.set_number(focused)?;
        let b = self.set_number(other)?;
        if a == b {
            return None;
        }
        let ia = self.set(a).windows.iter().position(|&w| w == focused)?;
        let ib = self.set(b).windows.iter().position(|&w| w == other)?;
        self.set_mut(a).windows[ia] = other;
        self.set_mut(b).windows[ib] = focused;
        self.set_mut(a).focused = Some(other);
        if self.set(b).focused == Some(other) {
            self.set_mut(b).focused = Some(focused);
        }
        Some(b)
    }

    /// Replace with a window that isn't managed yet: it takes the focused
    /// window's place, and that window moves to a new set. Returns where it
    /// went, or None when no set had room and it became unmanaged.
    pub fn replace_with_new(&mut self, focused: WindowId, new: WindowId) -> Option<usize> {
        let a = self.set_number(focused)?;
        if self.contains(new) {
            return None;
        }
        let index = self.set(a).windows.iter().position(|&w| w == focused)?;
        self.set_mut(a).windows[index] = new;
        self.set_mut(a).focused = Some(new);
        let target = self.lowest_empty(Some(a)).or_else(|| self.lowest_with_room(Some(a)))?;
        self.set_mut(target).insert(focused);
        Some(target)
    }
}

/// Magnetic stops at 1/3, 1/2 and 2/3; free in between, within limits.
pub fn snap(ratio: f64) -> f64 {
    for stop in [1.0 / 3.0, 0.5, 2.0 / 3.0] {
        if (ratio - stop).abs() < 0.035 {
            return stop;
        }
    }
    ratio.clamp(0.2, 0.8)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(s: &mut StageState, id: WindowId) -> AddOutcome {
        s.add(id, None, true)
    }

    #[test]
    fn new_window_joins_current_set_while_there_is_room() {
        let mut s = StageState::default();
        assert_eq!(add(&mut s, 1), AddOutcome::JoinedCurrent);
        assert_eq!(add(&mut s, 2), AddOutcome::JoinedCurrent);
        assert_eq!(s.set(1).windows, vec![1, 2]);
        assert_eq!(s.set(1).focused, Some(2));
    }

    #[test]
    fn new_window_opens_lowest_empty_set_when_full() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.set_mut(2).insert(9);
        assert_eq!(add(&mut s, 3), AddOutcome::Placed { number: 3, switched: true, because_full: true });
        assert_eq!(s.current, 3);
        assert_eq!(s.previous, Some(1));
    }

    #[test]
    fn background_window_does_not_move_the_stage() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        assert_eq!(s.add(3, None, false), AddOutcome::Placed { number: 2, switched: false, because_full: true });
        assert_eq!(s.current, 1);
    }

    #[test]
    fn preferred_set_wins_when_it_has_room() {
        let mut s = StageState::default();
        add(&mut s, 1);
        assert_eq!(s.add(2, Some(9), true), AddOutcome::Placed { number: 9, switched: true, because_full: false });
        assert_eq!(s.current, 9);
    }

    #[test]
    fn full_preferred_set_falls_back_to_the_rule() {
        let mut s = StageState::default();
        s.set_mut(9).insert(5);
        s.set_mut(9).insert(6);
        assert_eq!(s.add(1, Some(9), true), AddOutcome::JoinedCurrent);
    }

    #[test]
    fn every_set_full_leaves_window_unmanaged() {
        let mut s = StageState::default();
        for id in 1..=18 {
            s.add(id, None, false);
        }
        assert_eq!(add(&mut s, 99), AddOutcome::Unmanaged);
    }

    #[test]
    fn closing_last_window_keeps_the_empty_set() {
        let mut s = StageState::default();
        add(&mut s, 1);
        s.go_to(2);
        add(&mut s, 2);
        s.remove(2);
        assert_eq!(s.current, 2);
        assert!(s.set(2).is_empty());
    }

    #[test]
    fn closing_focused_window_focuses_the_other() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.remove(2);
        assert_eq!(s.set(1).focused, Some(1));
    }

    #[test]
    fn back_and_forth() {
        let mut s = StageState::default();
        s.go_to(3);
        s.back();
        assert_eq!(s.current, 1);
        s.back();
        assert_eq!(s.current, 3);
    }

    #[test]
    fn focusing_window_in_another_set_moves_the_stage() {
        let mut s = StageState::default();
        add(&mut s, 1);
        s.set_mut(4).insert(7);
        assert!(s.focus(7));
        assert_eq!(s.current, 4);
        assert!(!s.focus(7));
    }

    #[test]
    fn send_joins_set_with_room() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.send(2, 5);
        assert_eq!(s.set(1).windows, vec![1]);
        assert_eq!(s.set(1).focused, Some(1));
        assert_eq!(s.set(5).windows, vec![2]);
        assert_eq!(s.current, 1);
    }

    #[test]
    fn send_to_full_set_swaps_with_its_unfocused_window() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.set_mut(3).insert(30);
        s.set_mut(3).insert(31);
        s.set_mut(3).focused = Some(30);
        s.send(2, 3);
        assert_eq!(s.set(3).windows, vec![30, 2]);
        assert_eq!(s.set(1).windows, vec![1, 31]);
    }

    #[test]
    fn replace_trades_places() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.set_mut(3).insert(30);
        s.set_mut(3).insert(31);
        assert_eq!(s.replace(2, 31), Some(3));
        assert_eq!(s.set(1).windows, vec![1, 31]);
        assert_eq!(s.set(1).focused, Some(31));
        assert_eq!(s.set(3).windows, vec![30, 2]);
    }

    #[test]
    fn replace_with_new_app_pushes_focused_to_new_set() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.set_mut(2).insert(20);
        assert_eq!(s.replace_with_new(2, 50), Some(3));
        assert_eq!(s.set(1).windows, vec![1, 50]);
        assert_eq!(s.set(1).focused, Some(50));
        assert_eq!(s.set(3).windows, vec![2]);
    }

    #[test]
    fn undo_is_restoring_a_snapshot() {
        let mut s = StageState::default();
        add(&mut s, 1);
        s.set_mut(2).insert(20);
        let before = s.clone();
        s.replace(1, 20);
        s = before;
        assert_eq!(s.set(1).windows, vec![1]);
    }

    #[test]
    fn adopt_gives_front_window_its_own_set_and_groups_by_app() {
        let mut s = StageState::default();
        let w = |id, app: &str| (id, app.to_string());
        let left = s.adopt(&[w(1, "editor"), w(2, "browser"), w(3, "browser"), w(4, "browser"), w(5, "editor")]);
        assert_eq!(s.current, 1);
        assert_eq!(s.set(1).windows, vec![1]);
        assert_eq!(s.set(2).windows, vec![2, 3]);
        assert_eq!(s.set(3).windows, vec![4]);
        assert_eq!(s.set(4).windows, vec![5]);
        assert!(left.is_empty());
    }

    #[test]
    fn prune_drops_dead_windows() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.prune(&HashSet::from([2]));
        assert_eq!(s.all_windows(), vec![2]);
    }

    #[test]
    fn toggle_layout_needs_two_windows() {
        let mut s = StageState::default();
        add(&mut s, 1);
        s.toggle_layout();
        assert_eq!(s.current_set().layout, SetLayout::Split);
        add(&mut s, 2);
        s.toggle_layout();
        assert_eq!(s.current_set().layout, SetLayout::Stacked);
    }

    #[test]
    fn ratio_snaps() {
        assert_eq!(snap(0.51), 0.5);
        assert_eq!(snap(0.65), 2.0 / 3.0);
        assert_eq!(snap(0.42), 0.42);
        assert_eq!(snap(0.05), 0.2);
    }

    #[test]
    fn pull_in_splits_beside_focused() {
        let mut s = StageState::default();
        add(&mut s, 1);
        s.set_mut(3).insert(30);
        assert_eq!(s.pull_in(30, SplitAxis::Horizontal), Some(3));
        assert_eq!(s.set(1).windows, vec![1, 30]);
        assert_eq!(s.set(1).focused, Some(30));
        assert_eq!(s.set(1).axis, SplitAxis::Horizontal);
        assert!(s.set(3).is_empty());
    }

    #[test]
    fn pull_in_needs_room() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.set_mut(3).insert(30);
        assert_eq!(s.pull_in(30, SplitAxis::Vertical), None);
        assert_eq!(s.set(3).windows, vec![30]);
    }

    #[test]
    fn only_moves_the_other_window_out() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.current_set_mut().focused = Some(1);
        assert_eq!(s.only(), Some(2));
        assert_eq!(s.set(1).windows, vec![1]);
        assert_eq!(s.set(2).windows, vec![2]);
    }

    #[test]
    fn pane_focus_follows_the_axis() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.current_set_mut().focused = Some(1);
        assert!(s.focus_pane(PaneDirection::Right));
        assert_eq!(s.current_set().focused, Some(2));
        assert!(!s.focus_pane(PaneDirection::Down));
        s.set_axis(SplitAxis::Horizontal);
        assert!(s.focus_pane(PaneDirection::Up));
        assert_eq!(s.current_set().focused, Some(1));
    }

    #[test]
    fn toggle_axis_flips_the_split() {
        let mut s = StageState::default();
        add(&mut s, 1);
        assert!(!s.toggle_axis());
        add(&mut s, 2);
        assert!(s.toggle_axis());
        assert_eq!(s.current_set().axis, SplitAxis::Horizontal);
        s.toggle_axis();
        assert_eq!(s.current_set().axis, SplitAxis::Vertical);
        s.toggle_layout();
        s.toggle_axis();
        assert_eq!(s.current_set().layout, SetLayout::Split);
        assert_eq!(s.current_set().axis, SplitAxis::Vertical);
    }

    #[test]
    fn old_saved_sets_decode_as_side_by_side() {
        let json = r#"{"windows":[1,2],"focused":1,"layout":"split","ratio":0.5}"#;
        let set: FocusSet = serde_json::from_str(json).unwrap();
        assert_eq!(set.axis, SplitAxis::Vertical);
    }

    #[test]
    fn round_trips_through_json() {
        let mut s = StageState::default();
        add(&mut s, 1);
        add(&mut s, 2);
        s.toggle_layout();
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(serde_json::from_str::<StageState>(&json).unwrap(), s);
    }
}
