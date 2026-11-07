//! Focus's panels, each an undecorated always-on-top egui viewport: key
//! guide, shelf, switcher, picker, card, split-edge handle and the fade.

use super::{FocusFeature, PickItem, PickMode, WindowId};
use crate::windows::focus::stage::{numbers, SetLayout, SplitAxis};
use crate::windows::geometry::Rect;
use crate::windows::platform;
use eframe::egui::{self, Color32, Pos2, RichText, Sense, Stroke, Vec2, ViewportBuilder, ViewportId};
use std::time::{Duration, Instant};

const GUIDE_DELAY: Duration = Duration::from_millis(500);
const FADE: Duration = Duration::from_millis(180);
const SHELF_WIDTH: f32 = 240.0;

enum Act {
    GoTo(usize),
    CloseSwitcher,
    HideShelf,
    Choose(PickMode, PickItem),
    CancelPicker,
    Undo,
    CloseCard,
    Pin(String, usize),
    Ratio(f64, bool),
}

fn panel(rect: egui::Rect, passthrough: bool) -> ViewportBuilder {
    ViewportBuilder::default()
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top()
        .with_taskbar(false)
        .with_resizable(false)
        .with_active(false)
        .with_mouse_passthrough(passthrough)
        .with_position(rect.min)
        .with_inner_size(rect.size())
}

fn card_frame(ui: &egui::Ui) -> egui::Frame {
    egui::Frame::popup(ui.style()).rounding(14.0).inner_margin(egui::Margin::symmetric(16.0, 12.0))
}

fn bare(ctx: &egui::Context, add: impl FnOnce(&mut egui::Ui)) {
    egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, add);
}

const GUIDE_ROWS: &[(&str, &str)] = &[
    ("1-9", "Go to set"),
    ("Shift 1-9", "Move window to set"),
    ("Tab", "Previous set"),
    ("v", "Split side by side"),
    ("s", "Split top / bottom"),
    ("t", "Flip split direction"),
    ("o", "Only this window"),
    ("h j k l", "Focus pane"),
    ("Shift h j k l", "Swap panes"),
    ("Return", "Split / stacked"),
    ("Space", "Switcher"),
    ("r", "Replace this window"),
    ("f", "Zoom to full stage"),
    ("\\", "Float / unfloat"),
    ("", "Send prefix to app"),
    ("Esc", "Cancel"),
];

impl FocusFeature {
    fn logical(&self, r: Rect) -> egui::Rect {
        let s = self.scale.max(0.1) as f32;
        egui::Rect::from_min_size(Pos2::new(r.x as f32 / s, r.y as f32 / s), Vec2::new(r.w as f32 / s, r.h as f32 / s))
    }

    pub(super) fn draw(&mut self, ctx: &egui::Context) {
        let Some(display) = self.display() else { return };
        let now = Instant::now();
        let work = self.logical(display.work);
        let mut acts: Vec<Act> = Vec::new();

        for shot in self.capturer.poll() {
            let img = egui::ColorImage::from_rgba_unmultiplied([shot.w as usize, shot.h as usize], &shot.rgba);
            let tex = ctx.load_texture(format!("focus-thumb-{}", shot.id), img, egui::TextureOptions::LINEAR);
            self.thumbs.insert(shot.id, tex);
        }

        // The key guide (and the shelf) after a pause.
        let guide = self.leader.as_ref().is_some_and(|l| l.repeat_until.is_none() && now.duration_since(l.armed_at) >= GUIDE_DELAY);
        if guide && !self.shelf {
            self.shelf = true;
            self.capturer.request(self.state.all_windows());
        }
        if self.leader.is_some() && !guide {
            ctx.request_repaint_after(Duration::from_millis(50));
        }

        // Pointer at the left edge opens the shelf.
        if let Some((cx, cy)) = platform::cursor() {
            let f = display.frame;
            if f.contains(cx.max(f.x), cy) && cx <= f.x + 1.0 {
                let since = *self.edge_since.get_or_insert(now);
                if !self.shelf && now.duration_since(since) >= Duration::from_millis(200) && self.switcher.is_none() && self.picker.is_none() {
                    self.shelf = true;
                    self.capturer.request(self.state.all_windows());
                }
            } else {
                self.edge_since = None;
                if self.shelf && self.leader.is_none() && cx > f.x + (SHELF_WIDTH as f64 + 24.0) * self.scale {
                    self.shelf = false;
                }
            }
        }

        if guide {
            self.draw_guide(ctx, work);
        }
        if self.shelf {
            acts.extend(self.draw_shelf(ctx, work));
        }
        if let Some(s) = self.switcher.as_mut() {
            if now.duration_since(s.refreshed) > Duration::from_millis(1500) {
                s.refreshed = now;
                self.capturer.request(self.state.all_windows());
            }
            acts.extend(self.draw_switcher(ctx, work));
            ctx.request_repaint_after(Duration::from_millis(200));
        }
        if self.picker.is_some() {
            acts.extend(self.draw_picker(ctx));
        }
        if self.card.as_ref().is_some_and(|c| now >= c.until) {
            self.card = None;
        }
        if self.card.is_some() {
            acts.extend(self.draw_card(ctx, work));
        }
        acts.extend(self.draw_divider(ctx));
        self.draw_fade(ctx, display.frame);

        for a in acts {
            match a {
                Act::GoTo(n) => {
                    self.switcher = None;
                    self.shelf = false;
                    self.go_to(n);
                }
                Act::CloseSwitcher => self.switcher = None,
                Act::HideShelf => self.shelf = false,
                Act::Choose(mode, item) => self.choose(mode, item),
                Act::CancelPicker => self.cancel_picker(),
                Act::Undo => {
                    if let Some(before) = self.card.take().and_then(|c| c.undo) {
                        self.undo(before);
                    }
                }
                Act::CloseCard => self.card = None,
                Act::Pin(app, n) => self.toggle_pin(&app, n),
                Act::Ratio(r, done) => {
                    self.state.set_ratio(r);
                    if done {
                        self.drag = None;
                        self.apply(false);
                    } else if let Some(d) = self.drag.as_mut() {
                        if now.duration_since(d.last_apply) >= Duration::from_millis(40) {
                            d.last_apply = now;
                            self.apply(false);
                        }
                    } else {
                        self.drag = Some(super::Drag { last_apply: now });
                        self.apply(false);
                    }
                }
            }
        }
    }

    fn draw_guide(&self, ctx: &egui::Context, work: egui::Rect) {
        let size = Vec2::new(800.0, 250.0);
        let rect = egui::Rect::from_min_size(Pos2::new(work.center().x - size.x / 2.0, work.max.y - size.y - 16.0), size);
        let leader = self.leader_label();
        let (name, _) = self.set_names(self.state.current);
        let set_label = format!("Set {} · {}", self.state.current, name);
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-guide"), panel(rect, true), |ctx, _| {
            bare(ctx, |ui| {
                card_frame(ui).show(ui, |ui| {
                    ui.set_width(size.x - 40.0);
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(&leader).strong().monospace());
                        ui.heading("Focus");
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| ui.weak(&set_label));
                    });
                    ui.add_space(8.0);
                    egui::Grid::new("guide").num_columns(6).spacing([18.0, 6.0]).show(ui, |ui| {
                        for (i, (k, v)) in GUIDE_ROWS.iter().enumerate() {
                            let key = if k.is_empty() { leader.as_str() } else { k };
                            ui.label(RichText::new(key).strong().monospace());
                            ui.label(*v);
                            if i % 3 == 2 {
                                ui.end_row();
                            }
                        }
                    });
                });
            });
        });
    }

    fn previews(&self, ui: &mut egui::Ui, ids: &[WindowId], axis: SplitAxis, size: Vec2) {
        let n = ids.len().max(1) as f32;
        let each = if axis == SplitAxis::Vertical { Vec2::new(size.x / n - 4.0, size.y) } else { Vec2::new(size.x, size.y / n - 4.0) };
        let draw = |ui: &mut egui::Ui| {
            for &id in ids {
                match self.thumbs.get(&id) {
                    Some(t) => {
                        let ts = t.size_vec2();
                        let scale = (each.x / ts.x).min(each.y / ts.y);
                        ui.add(egui::Image::new((t.id(), ts * scale)).rounding(4.0));
                    }
                    None => {
                        let (r, _) = ui.allocate_exact_size(each, Sense::hover());
                        ui.painter().rect_filled(r, 4.0, ui.visuals().faint_bg_color);
                        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, self.name_of(id), egui::FontId::proportional(13.0), ui.visuals().weak_text_color());
                    }
                }
            }
        };
        if axis == SplitAxis::Vertical {
            ui.horizontal(draw);
        } else {
            ui.vertical(draw);
        }
    }

    fn draw_switcher(&self, ctx: &egui::Context, work: egui::Rect) -> Vec<Act> {
        let Some(sw) = self.switcher.as_ref() else { return Vec::new() };
        let size = Vec2::new(work.width().min(1260.0), work.height().min(840.0));
        let rect = egui::Rect::from_center_size(work.center(), size);
        let mut apps: Vec<(String, String)> = self.registry.values().filter(|w| self.state.contains(w.id)).map(|w| (w.app.clone(), w.app_name.clone())).collect();
        apps.sort();
        apps.dedup_by(|a, b| a.0 == b.0);
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-switcher"), panel(rect, false), |ctx, _| {
            let mut acts = Vec::new();
            bare(ctx, |ui| {
                egui::Frame::popup(ui.style()).rounding(18.0).inner_margin(16.0).show(ui, |ui| {
                    let cell = Vec2::new((size.x - 32.0 - 24.0) / 3.0, (size.y - 32.0 - 24.0) / 3.0);
                    egui::Grid::new("sets").spacing([12.0, 12.0]).show(ui, |ui| {
                        for n in numbers() {
                            let set = self.state.set(n);
                            let selected = sw.selection == n;
                            let stroke = if selected {
                                Stroke::new(3.0_f32, ui.visuals().selection.stroke.color)
                            } else if n == self.state.current {
                                Stroke::new(1.5_f32, ui.visuals().widgets.active.bg_stroke.color)
                            } else {
                                Stroke::new(1.0_f32, ui.visuals().widgets.noninteractive.bg_stroke.color)
                            };
                            let resp = egui::Frame::none().stroke(stroke).rounding(12.0).inner_margin(10.0).show(ui, |ui| {
                                ui.set_min_size(cell - Vec2::splat(20.0));
                                ui.set_max_size(cell - Vec2::splat(20.0));
                                let (name, list) = self.set_names(n);
                                ui.horizontal(|ui| {
                                    ui.label(RichText::new(n.to_string()).strong().size(18.0));
                                    ui.label(RichText::new(if set.is_empty() { "Empty".to_string() } else { name }).strong());
                                });
                                if !set.is_empty() {
                                    ui.weak(list);
                                    let ids: Vec<WindowId> = if set.layout == SetLayout::Stacked { set.focused.into_iter().collect() } else { set.windows.clone() };
                                    let avail = ui.available_size();
                                    self.previews(ui, &ids, set.axis, avail);
                                }
                                let pinned: Vec<&String> = self.pins.iter().filter(|(_, &v)| v == n).map(|(k, _)| k).collect();
                                if !pinned.is_empty() {
                                    ui.weak(format!("Pinned: {}", pinned.len()));
                                }
                            });
                            let resp = ui.interact(resp.response.rect, ui.id().with(("set", n)), Sense::click());
                            if resp.clicked() {
                                acts.push(Act::GoTo(n));
                            }
                            resp.context_menu(|ui| {
                                ui.label(RichText::new(format!("Pin to set {n}")).strong());
                                for (app, name) in &apps {
                                    let mut on = self.pins.get(app) == Some(&n);
                                    if ui.checkbox(&mut on, name.as_str()).clicked() {
                                        acts.push(Act::Pin(app.clone(), n));
                                        ui.close_menu();
                                    }
                                }
                            });
                            if n % 3 == 0 {
                                ui.end_row();
                            }
                        }
                    });
                });
            });
            if ctx.input(|i| i.viewport().close_requested()) {
                acts.push(Act::CloseSwitcher);
            }
            acts
        })
    }

    fn draw_shelf(&self, ctx: &egui::Context, work: egui::Rect) -> Vec<Act> {
        let sets: Vec<usize> = self.state.occupied().into_iter().filter(|&n| n != self.state.current).collect();
        let height = (sets.len().max(1) as f32 * 150.0 + 24.0).min(work.height());
        let rect = egui::Rect::from_min_size(Pos2::new(work.min.x, work.center().y - height / 2.0), Vec2::new(SHELF_WIDTH, height));
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-shelf"), panel(rect, false), |ctx, _| {
            let mut acts = Vec::new();
            bare(ctx, |ui| {
                card_frame(ui).show(ui, |ui| {
                    ui.set_width(SHELF_WIDTH - 40.0);
                    if sets.is_empty() {
                        ui.weak("No other sets");
                    }
                    for &n in &sets {
                        let set = self.state.set(n);
                        let r = ui
                            .vertical(|ui| {
                                let (name, _) = self.set_names(n);
                                ui.label(RichText::new(format!("{n}  {name}")).strong());
                                self.previews(ui, &set.windows, set.axis, Vec2::new(SHELF_WIDTH - 40.0, 100.0));
                            })
                            .response;
                        if ui.interact(r.rect, ui.id().with(("shelf", n)), Sense::click()).clicked() {
                            acts.push(Act::GoTo(n));
                        }
                        ui.separator();
                    }
                });
            });
            if ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
                acts.push(Act::HideShelf);
            }
            acts
        })
    }

    fn draw_picker(&self, ctx: &egui::Context) -> Vec<Act> {
        let Some(p) = self.picker.as_ref() else { return Vec::new() };
        let items = self.picker_items(p);
        let rect = self.logical(p.rect).shrink(8.0);
        let title = match (p.mode, &p.beside) {
            (PickMode::Replace, Some(b)) => format!("Replace {b} with"),
            (PickMode::Split(SplitAxis::Vertical), Some(b)) => format!("Beside {b}"),
            (PickMode::Split(SplitAxis::Horizontal), Some(b)) => format!("Below {b}"),
            _ => format!("Open on set {}", self.state.current),
        };
        let mode = p.mode;
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-picker"), panel(rect, false), |ctx, _| {
            let mut acts = Vec::new();
            bare(ctx, |ui| {
                egui::Frame::popup(ui.style()).rounding(16.0).inner_margin(16.0).show(ui, |ui| {
                    ui.set_min_size(rect.size() - Vec2::splat(32.0));
                    ui.heading(title.as_str());
                    if p.searching {
                        egui::Frame::group(ui.style()).show(ui, |ui| {
                            ui.set_width(ui.available_width());
                            let shown = if p.query.is_empty() { "Search apps and windows".to_string() } else { format!("{}|", p.query) };
                            if p.query.is_empty() {
                                ui.weak(shown);
                            } else {
                                ui.label(shown);
                            }
                        });
                    }
                    ui.add_space(6.0);
                    egui::ScrollArea::vertical().max_height(ui.available_height() - 28.0).show(ui, |ui| {
                        if items.is_empty() {
                            ui.weak(if p.searching { "Nothing matches" } else { "No other windows. Press / to search apps." });
                        }
                        for (i, item) in items.iter().enumerate() {
                            let selected = i == p.selection;
                            let text = RichText::new(format!("{}   {}", item.label, item.detail));
                            let r = ui.add_sized([ui.available_width(), 28.0], egui::SelectableLabel::new(selected, text));
                            if selected {
                                r.scroll_to_me(None);
                            }
                            if r.clicked() {
                                acts.push(Act::Choose(mode, item.clone()));
                            }
                        }
                    });
                    ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
                        let hint = if p.searching { "Type to search · ↑↓ move · Return open · Esc back" } else { "j k move · Return choose · / search · Esc cancel" };
                        ui.horizontal(|ui| {
                            ui.weak(hint);
                            if ui.small_button("Cancel").clicked() {
                                acts.push(Act::CancelPicker);
                            }
                        });
                    });
                });
            });
            acts
        })
    }

    fn draw_card(&self, ctx: &egui::Context, work: egui::Rect) -> Vec<Act> {
        let Some(card) = self.card.as_ref() else { return Vec::new() };
        let size = Vec2::new(460.0, 84.0);
        let rect = egui::Rect::from_min_size(Pos2::new(work.center().x - size.x / 2.0, work.max.y - size.y - 40.0), size);
        let has_undo = card.undo.is_some();
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-card"), panel(rect, !has_undo), |ctx, _| {
            let mut acts = Vec::new();
            bare(ctx, |ui| {
                card_frame(ui).show(ui, |ui| {
                    ui.set_width(size.x - 40.0);
                    ui.horizontal(|ui| {
                        ui.vertical(|ui| {
                            ui.label(RichText::new(&card.title).strong().size(15.0));
                            if !card.subtitle.is_empty() {
                                ui.weak(&card.subtitle);
                            }
                        });
                        if has_undo {
                            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                if ui.button("Undo").clicked() {
                                    acts.push(Act::Undo);
                                }
                                if ui.small_button("✕").clicked() {
                                    acts.push(Act::CloseCard);
                                }
                            });
                        }
                    });
                });
            });
            acts
        })
    }

    /// The edge between two split windows: drag it to change the split.
    fn draw_divider(&self, ctx: &egui::Context) -> Vec<Act> {
        let set = self.state.current_set();
        if set.windows.len() != 2
            || set.layout != SetLayout::Split
            || self.zoomed.is_some()
            || self.open_split.is_some()
            || self.switcher.is_some()
            || self.picker.is_some()
        {
            return Vec::new();
        }
        let layout = self.layout();
        let (a, _) = layout.split(set.ratio, set.axis);
        let inner = layout.inner();
        let thick = layout.gap.max(8.0 * self.scale);
        let px = match set.axis {
            SplitAxis::Vertical => Rect::new(a.max_x() + layout.gap / 2.0 - thick / 2.0, inner.y + inner.h * 0.25, thick, inner.h * 0.5),
            SplitAxis::Horizontal => Rect::new(inner.x + inner.w * 0.25, a.max_y() + layout.gap / 2.0 - thick / 2.0, inner.w * 0.5, thick),
        };
        let rect = self.logical(px);
        let axis = set.axis;
        let dragging = self.drag.is_some();
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-divider"), panel(rect, false), |ctx, _| {
            let mut acts = Vec::new();
            bare(ctx, |ui| {
                let r = ui.interact(ui.max_rect(), ui.id().with("divider"), Sense::drag());
                let icon = if axis == SplitAxis::Vertical { egui::CursorIcon::ResizeHorizontal } else { egui::CursorIcon::ResizeVertical };
                if r.hovered() || r.dragged() {
                    ui.ctx().set_cursor_icon(icon);
                    let bar = if axis == SplitAxis::Vertical {
                        egui::Rect::from_center_size(ui.max_rect().center(), Vec2::new(4.0, 60.0))
                    } else {
                        egui::Rect::from_center_size(ui.max_rect().center(), Vec2::new(60.0, 4.0))
                    };
                    ui.painter().rect_filled(bar, 2.0, Color32::from_white_alpha(160));
                }
                let pos = || platform::cursor().map(|(x, y)| if axis == SplitAxis::Vertical { x } else { y });
                if r.dragged() {
                    if let Some(p) = pos() {
                        acts.push(Act::Ratio(layout.ratio_at(p, axis), false));
                    }
                }
                if r.drag_stopped() || (dragging && !r.dragged() && !ui.input(|i| i.pointer.any_down())) {
                    if let Some(p) = pos() {
                        acts.push(Act::Ratio(layout.ratio_at(p, axis), true));
                    }
                }
            });
            acts
        })
    }

    fn draw_fade(&mut self, ctx: &egui::Context, frame: Rect) {
        let Some(fade) = self.fade.as_mut() else { return };
        let now = Instant::now();
        let alpha = match fade.started {
            None => 1.0,
            Some(t) => 1.0 - (now.duration_since(t).as_secs_f32() / FADE.as_secs_f32()).min(1.0),
        };
        let tex = (fade.texture.id(), fade.texture.size_vec2());
        let rect = self.logical(frame);
        ctx.show_viewport_immediate(ViewportId::from_hash_of("focus-fade"), panel(rect, true), |ctx, _| {
            bare(ctx, |ui| {
                let tint = Color32::from_white_alpha((alpha * 255.0) as u8);
                ui.painter().image(tex.0, ui.max_rect(), egui::Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)), tint);
            });
        });
        ctx.request_repaint();
        let Some(fade) = self.fade.as_mut() else { return };
        fade.frames += 1;
        // Let the still reach the screen before the windows move under it.
        if fade.started.is_none() && fade.frames >= 3 {
            fade.started = Some(now);
            if let Some(change) = fade.pending.take() {
                change(self);
            }
        } else if fade.started.is_some_and(|t| now.duration_since(t) >= FADE) {
            self.fade = None;
        }
    }
}
