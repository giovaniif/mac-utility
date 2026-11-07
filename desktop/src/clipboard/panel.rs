//! Paste-style strip of cards along the bottom of the display under the
//! pointer. Mirrors ClipboardPanel.swift.

use super::item::{now, ClipboardItem, Kind};
use super::platform::WorkArea;
use super::store::ClipboardStore;
use eframe::egui::{self, Color32, Key, Modifiers, RichText, Stroke, TextureHandle, Vec2};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

const HEIGHT: f32 = 300.0;
const MARGIN: f32 = 12.0;
const CARD: Vec2 = Vec2::new(220.0, 210.0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Close,
    ToggleFavoritesOnly,
    Move(i32),
    Paste { plain: bool },
    QuickPaste { index: usize, plain: bool },
    TogglePin,
    Delete,
}

/// What a key press does in the panel. Anything else goes to the search field.
pub fn action_for(key: Key, mods: Modifiers, query_empty: bool) -> Option<Action> {
    let digit = [Key::Num1, Key::Num2, Key::Num3, Key::Num4, Key::Num5, Key::Num6, Key::Num7, Key::Num8, Key::Num9]
        .iter()
        .position(|k| *k == key);
    if mods.command {
        return match key {
            Key::D | Key::P => Some(Action::TogglePin),
            _ => digit.map(|index| Action::QuickPaste { index, plain: mods.shift }),
        };
    }
    Some(match key {
        Key::Escape => Action::Close,
        Key::Tab => Action::ToggleFavoritesOnly,
        Key::ArrowLeft => Action::Move(-1),
        Key::ArrowRight => Action::Move(1),
        Key::Enter => Action::Paste { plain: mods.shift },
        Key::Delete => Action::Delete,
        Key::Backspace if query_empty => Action::Delete,
        _ => return None,
    })
}

/// Indices into `items` shown for the current filter, newest first.
pub fn filter(items: &[ClipboardItem], favorites_only: bool, matches: Option<&HashSet<Uuid>>) -> Vec<usize> {
    items
        .iter()
        .enumerate()
        .filter(|(_, i)| !favorites_only || i.pinned)
        .filter(|(_, i)| matches.map_or(true, |m| m.contains(&i.id)))
        .map(|(n, _)| n)
        .collect()
}

pub fn moved(selection: usize, delta: i32, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    (selection as i64 + i64::from(delta)).clamp(0, count as i64 - 1) as usize
}

/// "now", "5m", "3h", "2d".
pub fn relative(seconds_ago: f64) -> String {
    let s = seconds_ago.max(0.0) as u64;
    match s {
        0..=59 => "now".into(),
        60..=3599 => format!("{}m", s / 60),
        3600..=86_399 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86_400),
    }
}

#[derive(Default)]
pub struct Panel {
    pub visible: bool,
    query: String,
    selection: usize,
    favorites_only: bool,
    area: Option<(egui::Pos2, Vec2)>,
    focused_once: bool,
    scroll_to_selection: bool,
    thumbnails: HashMap<Uuid, Option<TextureHandle>>,
}

pub enum Command {
    Paste(Uuid, bool),
    /// Closed with Esc: hand focus back to the previous window.
    Closed,
}

impl Panel {
    pub fn show(&mut self, area: Option<WorkArea>, egui: &egui::Context) {
        self.query.clear();
        self.selection = 0;
        self.favorites_only = false;
        self.focused_once = false;
        self.scroll_to_selection = true;
        self.area = area.map(|a| {
            let scale = a.scale.unwrap_or_else(|| egui.pixels_per_point()).max(0.5);
            let (x, y, w, h) = (a.x / scale, a.y / scale, a.width / scale, a.height / scale);
            (egui::pos2(x + MARGIN, y + h - HEIGHT - MARGIN), Vec2::new(w - MARGIN * 2.0, HEIGHT))
        });
        if self.area.is_none() {
            let monitor = egui.input(|i| i.viewport().monitor_size).unwrap_or(Vec2::new(1280.0, 800.0));
            self.area = Some((egui::pos2(MARGIN, monitor.y - HEIGHT - MARGIN * 4.0), Vec2::new(monitor.x - MARGIN * 2.0, HEIGHT)));
        }
        self.visible = true;
    }

    pub fn hide(&mut self) {
        self.visible = false;
    }

    fn results(&self, store: &ClipboardStore) -> Vec<usize> {
        let matches = store.search(&self.query).unwrap_or_else(|e| {
            log::warn!("clipboard search: {e}");
            None
        });
        filter(store.items(), self.favorites_only, matches.as_ref())
    }

    /// Draws the panel if visible and returns a paste request.
    pub fn ui(&mut self, egui: &egui::Context, store: &mut ClipboardStore) -> Option<Command> {
        if !self.visible {
            return None;
        }
        let (pos, size) = self.area?;
        let builder = egui::ViewportBuilder::default()
            .with_title("Clipboard history")
            .with_decorations(false)
            .with_transparent(true)
            .with_always_on_top()
            .with_taskbar(false)
            .with_resizable(false)
            .with_active(true)
            .with_position(pos)
            .with_inner_size(size);
        let id = egui::ViewportId::from_hash_of("clipboard-panel");
        let mut command = None;
        egui.show_viewport_immediate(id, builder, |ctx, _| {
            command = self.frame(ctx, store);
        });
        command
    }

    fn frame(&mut self, ctx: &egui::Context, store: &mut ClipboardStore) -> Option<Command> {
        let focused = ctx.input(|i| i.viewport().focused);
        if focused == Some(true) {
            self.focused_once = true;
        } else if self.focused_once && focused == Some(false) {
            // Clicked elsewhere: close like the macOS panel on resign key.
            self.hide();
            return None;
        }
        if !self.focused_once {
            ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
        }
        if ctx.input(|i| i.viewport().close_requested()) {
            self.hide();
            return None;
        }

        let query_empty = self.query.is_empty();
        let actions: Vec<Action> = ctx.input_mut(|i| {
            let mut actions = Vec::new();
            i.events.retain(|e| match e {
                egui::Event::Key { key, pressed, modifiers, .. } => match action_for(*key, *modifiers, query_empty) {
                    Some(a) => {
                        if *pressed {
                            actions.push(a);
                        }
                        false
                    }
                    None => true,
                },
                _ => true,
            });
            actions
        });

        let mut results = self.results(store);
        let mut command = None;
        for action in actions {
            let selected = results.get(self.selection).map(|&n| store.items()[n].id);
            match action {
                Action::Close => {
                    self.hide();
                    command = Some(Command::Closed);
                }
                Action::ToggleFavoritesOnly => {
                    self.favorites_only = !self.favorites_only;
                    self.selection = 0;
                }
                Action::Move(d) => {
                    self.selection = moved(self.selection, d, results.len());
                    self.scroll_to_selection = true;
                }
                Action::Paste { plain } => command = selected.map(|id| Command::Paste(id, plain)),
                Action::QuickPaste { index, plain } => {
                    command = results.get(index).map(|&n| Command::Paste(store.items()[n].id, plain))
                }
                Action::TogglePin => {
                    if let Some(id) = selected {
                        log_err(store.toggle_pin(id));
                    }
                }
                Action::Delete => {
                    if let Some(id) = selected {
                        log_err(store.delete(id));
                        self.thumbnails.remove(&id);
                    }
                }
            }
            results = self.results(store);
            self.selection = moved(self.selection, 0, results.len());
        }
        if command.is_some() || !self.visible {
            return command;
        }

        let fill = if ctx.style().visuals.dark_mode {
            Color32::from_rgba_unmultiplied(30, 30, 32, 242)
        } else {
            Color32::from_rgba_unmultiplied(245, 245, 247, 242)
        };
        let frame = egui::Frame::none().fill(fill).rounding(16.0).inner_margin(14.0).stroke(Stroke::new(1.0_f32, Color32::from_gray(90)));
        egui::CentralPanel::default().frame(frame).show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.selectable_label(!self.favorites_only, "All").clicked() {
                    self.favorites_only = false;
                    self.selection = 0;
                }
                if ui.selectable_label(self.favorites_only, "★ Favorites").clicked() {
                    self.favorites_only = true;
                    self.selection = 0;
                }
                ui.add_space(8.0);
                let search = ui.add(
                    egui::TextEdit::singleline(&mut self.query)
                        .hint_text("Search clipboard history")
                        .frame(false)
                        .desired_width(320.0)
                        .font(egui::TextStyle::Heading),
                );
                if search.changed() {
                    self.selection = 0;
                    self.scroll_to_selection = true;
                }
                if !search.has_focus() {
                    search.request_focus();
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.weak("⏎ paste  ⇧⏎ plain  Ctrl+D favorite  Tab favorites  Del delete  Esc close");
                });
            });
            ui.add_space(10.0);

            let results = self.results(store);
            if results.is_empty() {
                let msg = if !self.query.is_empty() {
                    "No matches"
                } else if self.favorites_only {
                    "No favorites yet. Press Ctrl+D on an item"
                } else {
                    "Nothing copied yet"
                };
                ui.centered_and_justified(|ui| ui.weak(msg));
                return;
            }
            egui::ScrollArea::horizontal().show(ui, |ui| {
                ui.horizontal(|ui| {
                    for (index, &n) in results.iter().enumerate() {
                        let item = store.items()[n].clone();
                        let selected = index == self.selection;
                        let thumb = self.thumbnail(ctx, store, &item);
                        let response = card(ui, &item, index, selected, thumb.as_ref());
                        if selected && self.scroll_to_selection {
                            response.scroll_to_me(None);
                        }
                        if response.double_clicked() {
                            command = Some(Command::Paste(item.id, false));
                        } else if response.clicked() {
                            self.selection = index;
                        }
                        response.context_menu(|ui| {
                            let label = if item.pinned { "Remove from Favorites" } else { "Add to Favorites" };
                            if ui.button(label).clicked() {
                                log_err(store.toggle_pin(item.id));
                                ui.close_menu();
                            }
                            if ui.button("Delete").clicked() {
                                log_err(store.delete(item.id));
                                ui.close_menu();
                            }
                        });
                    }
                });
            });
            self.scroll_to_selection = false;
        });
        command
    }

    fn thumbnail(&mut self, ctx: &egui::Context, store: &ClipboardStore, item: &ClipboardItem) -> Option<TextureHandle> {
        if item.kind != Kind::Image {
            return None;
        }
        self.thumbnails
            .entry(item.id)
            .or_insert_with(|| {
                let name = item.thumbnail_file.as_ref().or(item.image_file.as_ref())?;
                let img = image::open(store.image_path(name)).ok()?.to_rgba8();
                let size = [img.width() as usize, img.height() as usize];
                let color = egui::ColorImage::from_rgba_unmultiplied(size, img.as_raw());
                Some(ctx.load_texture(format!("clip-{}", item.id), color, Default::default()))
            })
            .clone()
    }
}

fn log_err(r: anyhow::Result<()>) {
    if let Err(e) = r {
        log::error!("clipboard store: {e}");
    }
}

fn card(ui: &mut egui::Ui, item: &ClipboardItem, index: usize, selected: bool, thumb: Option<&TextureHandle>) -> egui::Response {
    let stroke = if selected {
        Stroke::new(3.0_f32, ui.visuals().selection.bg_fill)
    } else {
        Stroke::new(1.0_f32, ui.visuals().widgets.noninteractive.bg_stroke.color)
    };
    let inner = egui::Frame::none()
        .fill(ui.visuals().extreme_bg_color)
        .rounding(10.0)
        .stroke(stroke)
        .inner_margin(10.0)
        .show(ui, |ui| {
            ui.set_min_size(CARD - Vec2::splat(20.0));
            ui.set_max_size(CARD - Vec2::splat(20.0));
            ui.vertical(|ui| {
                ui.horizontal(|ui| {
                    if let Some(app) = &item.source_app {
                        let name = app.strip_suffix(".exe").unwrap_or(app);
                        ui.label(RichText::new(name).small().strong());
                    }
                    ui.label(RichText::new(relative(now() - item.date)).small().weak());
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if index < 9 {
                            ui.label(RichText::new(format!("Ctrl+{}", index + 1)).small().monospace().weak());
                        }
                        if item.pinned {
                            ui.label(RichText::new("★").color(Color32::from_rgb(240, 190, 40)));
                        }
                    });
                });
                ui.add_space(4.0);
                match item.kind {
                    Kind::Text | Kind::RichText => {
                        let text: String = item.text.as_deref().unwrap_or("").chars().take(600).collect();
                        ui.add(egui::Label::new(text).wrap());
                    }
                    Kind::Image => match thumb {
                        Some(t) => {
                            ui.add(egui::Image::new(t).max_size(ui.available_size()).maintain_aspect_ratio(true));
                        }
                        None => {
                            ui.label("Image");
                        }
                    },
                    Kind::Files => {
                        for path in item.files.iter().take(8) {
                            let name = path.rsplit(['/', '\\']).next().unwrap_or(path);
                            ui.add(egui::Label::new(format!("📄 {name}")).truncate());
                        }
                    }
                }
            });
        });
    ui.interact(inner.response.rect, ui.id().with(item.id), egui::Sense::click())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctrl() -> Modifiers {
        Modifiers { command: true, ctrl: true, ..Default::default() }
    }

    #[test]
    fn keys() {
        let none = Modifiers::NONE;
        assert_eq!(action_for(Key::Escape, none, true), Some(Action::Close));
        assert_eq!(action_for(Key::Tab, none, false), Some(Action::ToggleFavoritesOnly));
        assert_eq!(action_for(Key::ArrowLeft, none, true), Some(Action::Move(-1)));
        assert_eq!(action_for(Key::Enter, Modifiers::SHIFT, true), Some(Action::Paste { plain: true }));
        assert_eq!(action_for(Key::Backspace, none, true), Some(Action::Delete));
        assert_eq!(action_for(Key::Backspace, none, false), None);
        assert_eq!(action_for(Key::Delete, none, false), Some(Action::Delete));
        assert_eq!(action_for(Key::D, ctrl(), false), Some(Action::TogglePin));
        assert_eq!(action_for(Key::Num3, ctrl(), true), Some(Action::QuickPaste { index: 2, plain: false }));
        assert_eq!(action_for(Key::Num0, ctrl(), true), None);
        assert_eq!(action_for(Key::A, none, true), None);
        assert_eq!(action_for(Key::Num3, none, true), None);
    }

    #[test]
    fn filtering_and_moving() {
        let mut items: Vec<_> = ["a", "b", "c"].iter().map(|t| ClipboardItem::text((*t).into(), None, None)).collect();
        items[1].pinned = true;
        assert_eq!(filter(&items, false, None), [0, 1, 2]);
        assert_eq!(filter(&items, true, None), [1]);
        let m = HashSet::from([items[0].id, items[1].id]);
        assert_eq!(filter(&items, false, Some(&m)), [0, 1]);
        assert_eq!(filter(&items, true, Some(&HashSet::new())), Vec::<usize>::new());
        assert_eq!(moved(0, -1, 3), 0);
        assert_eq!(moved(1, 5, 3), 2);
        assert_eq!(moved(4, 0, 2), 1);
        assert_eq!(moved(3, 1, 0), 0);
    }

    #[test]
    fn relative_time() {
        assert_eq!(relative(5.0), "now");
        assert_eq!(relative(125.0), "2m");
        assert_eq!(relative(7200.0), "2h");
        assert_eq!(relative(3.0 * 86_400.0), "3d");
    }
}
