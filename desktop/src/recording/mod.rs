//! Screen recording (Ctrl+Shift+5). Pick an area, a window (Space, then
//! click) or a whole display (click or Return); a floating bar then offers
//! camera, microphone and keystroke switches plus Record, and while recording
//! shows the elapsed time, Pause and Stop. ffmpeg does the capture and H.264
//! encoding; pausing closes the current segment and Stop joins them. The
//! result waits in the cache folder until Save moves it.

mod camera;
mod ffmpeg;
mod geom;
mod keys;
mod platform;
mod prefs;
mod save;

use crate::feature::{Ctx, Feature, Shortcut};
use camera::Camera;
use eframe::egui::{self, Color32, Pos2, Vec2, ViewportBuilder, ViewportCommand, ViewportId};
use ffmpeg::Platform;
use geom::Rect;
use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use keys::{KeyLog, Stroke};
use prefs::Prefs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Window title the Windows backend uses to find the bar and hide it from capture.
const BAR_TITLE: &str = "Utility Recording Controls";
const BAR_SIZE: Vec2 = Vec2::new(500.0, 52.0);
const CAMERA_PT: f32 = 180.0;
const PILL_SIZE: Vec2 = Vec2::new(720.0, 64.0);

pub struct RecordingFeature {
    phase: Phase,
    prefs: Prefs,
    data_dir: PathBuf,
    ffmpeg: Option<PathBuf>,
    cam_tex: Option<egui::TextureHandle>,
}

enum Phase {
    Idle,
    Picking(Picker),
    Active(Box<Session>),
    Finishing(Receiver<Result<PathBuf, String>>),
    Done { file: PathBuf, saving: Option<Receiver<Result<Option<PathBuf>, String>>> },
}

impl RecordingFeature {
    pub fn new() -> Self {
        Self { phase: Phase::Idle, prefs: Prefs::default(), data_dir: PathBuf::new(), ffmpeg: None, cam_tex: None }
    }

    fn cache_dir(&self) -> PathBuf {
        directories::ProjectDirs::from("com", "giovani", "MacUtility")
            .map(|d| d.cache_dir().to_path_buf())
            .unwrap_or_else(|| self.data_dir.join("cache"))
            .join("Recordings")
    }

    fn begin(&mut self, ctx: &mut Ctx) {
        let Some(_) = Platform::current() else {
            ctx.hud.push("Screen recording isn't available here".into());
            return;
        };
        if let Err(msg) = platform::check_session() {
            ctx.hud.push(msg);
            return;
        }
        if self.ffmpeg.is_none() {
            self.ffmpeg = ffmpeg::find_ffmpeg();
        }
        if self.ffmpeg.is_none() {
            log::warn!("screen recording: ffmpeg not found on PATH");
            ctx.hud.push("Install ffmpeg to record the screen".into());
            return;
        }
        let monitors = platform::monitors();
        let Some(virt) = geom::virtual_bounds(&monitors) else {
            ctx.hud.push("No displays found".into());
            return;
        };
        // Snapshot windows before our overlay exists so it never matches itself.
        let windows = platform::windows();
        self.phase = Phase::Picking(Picker { monitors, windows, virt, drag_from: None, window_mode: false, frames: 0 });
    }

    fn open_session(&mut self, area: Rect, monitors: &[Rect], ctx: &mut Ctx) {
        let (Some(platform), Some(ffmpeg)) = (Platform::current(), self.ffmpeg.clone()) else { return };
        let area = area.even();
        if area.w < 16 || area.h < 16 {
            ctx.hud.push("That area is too small".into());
            self.phase = Phase::Idle;
            return;
        }
        let workdir = self.cache_dir().join(format!(".session-{}", uuid::Uuid::new_v4()));
        if let Err(e) = std::fs::create_dir_all(&workdir) {
            ctx.hud.push(format!("Can't record: {e}"));
            self.phase = Phase::Idle;
            return;
        }
        let center = (area.x + area.w / 2, area.y + area.h / 2);
        let monitor = geom::monitor_at(monitors, center).unwrap_or(area);
        let devices = platform::devices(&ffmpeg);
        let ppp = ctx.egui.pixels_per_point();
        let cam_pos = Pos2::new(area.x as f32 / ppp + 24.0, area.bottom() as f32 / ppp - 24.0 - CAMERA_PT);
        let mut s = Session {
            area,
            monitor,
            platform,
            ffmpeg,
            workdir,
            devices,
            recording: false,
            paused: false,
            child: None,
            segments: Vec::new(),
            stoppers: Vec::new(),
            run_start: None,
            accum: Duration::ZERO,
            camera: None,
            keyhook: None,
            key_rx: None,
            keylog: KeyLog::default(),
            excluded: false,
            cam_pos,
        };
        if self.prefs.camera {
            s.set_camera(true, ctx);
        }
        if self.prefs.keys {
            s.set_keys(true);
        }
        self.phase = Phase::Active(Box::new(s));
    }

    fn stop(&mut self, ctx: &mut Ctx) {
        let Phase::Active(s) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
        let out = self.cache_dir().join(ffmpeg::file_name(
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        ));
        ctx.hud.push("Finishing recording…".into());
        self.phase = Phase::Finishing(s.finish(out));
    }

    fn cancel(&mut self) {
        match std::mem::replace(&mut self.phase, Phase::Idle) {
            Phase::Active(s) => s.discard(),
            Phase::Done { file, .. } => {
                let _ = std::fs::remove_file(file);
            }
            _ => {}
        }
    }

    fn start_recording(&mut self, ctx: &mut Ctx) {
        let mic = self.prefs.mic;
        if let Phase::Active(s) = &mut self.phase {
            if mic && s.devices.1.is_none() {
                ctx.hud.push("No microphone found".into());
            }
            match s.start_segment(mic) {
                Ok(()) => s.recording = true,
                Err(e) => {
                    log::error!("screen recording: {e}");
                    ctx.hud.push("Couldn't start recording".into());
                }
            }
        }
    }

    fn update_active(&mut self, ctx: &mut Ctx) {
        let Phase::Active(s) = &mut self.phase else { return };
        let ppp = ctx.egui.pixels_per_point();

        // ffmpeg died on its own: keep what we have.
        if let Some(c) = &mut s.child {
            if let Ok(Some(status)) = c.try_wait() {
                log::error!("ffmpeg exited with {status}; see {}", s.workdir.display());
                ctx.hud.push("Recording stopped: ffmpeg failed".into());
                s.child = None;
                s.run_start = None;
                self.stop(ctx);
                return;
            }
        }
        if let Some(cam) = &mut s.camera {
            if cam.exited() {
                ctx.hud.push("Camera unavailable".into());
                s.camera = None;
            } else if let Some(frame) = cam.take_frame() {
                let n = ffmpeg::CAMERA_SIZE as usize;
                let img = egui::ColorImage::from_rgba_unmultiplied([n, n], &frame);
                match &mut self.cam_tex {
                    Some(t) => t.set(img, egui::TextureOptions::LINEAR),
                    None => self.cam_tex = Some(ctx.egui.load_texture("recording-camera", img, egui::TextureOptions::LINEAR)),
                }
            }
        }
        if let Some(rx) = &s.key_rx {
            let now = Instant::now();
            while let Ok(k) = rx.try_recv() {
                s.keylog.push(&k, now);
            }
        }

        if s.camera.is_some() {
            camera_bubble(ctx.egui, s.cam_pos, self.cam_tex.as_ref());
        }
        if s.recording && !s.paused && self.prefs.keys {
            if let Some(text) = s.keylog.text(Instant::now()) {
                let pos = Pos2::new(
                    (s.area.x + s.area.w / 2) as f32 / ppp - PILL_SIZE.x / 2.0,
                    s.area.bottom() as f32 / ppp - 40.0 - PILL_SIZE.y,
                );
                key_pill(ctx.egui, pos, &text);
            }
        }

        let bar_phys = (BAR_SIZE * ppp).round();
        let (bx, by) = bar_origin(s.platform == Platform::Windows, s.area, s.monitor, (bar_phys.x as i32, bar_phys.y as i32));
        let action = bar(ctx.egui, Pos2::new(bx as f32 / ppp, by as f32 / ppp), s, &mut self.prefs);
        if !s.excluded {
            s.excluded = platform::exclude_from_capture(BAR_TITLE);
        }
        match action {
            BarAction::None => {}
            BarAction::Cancel => self.cancel(),
            BarAction::Record => {
                self.prefs.save(&self.data_dir);
                self.start_recording(ctx);
            }
            BarAction::Pause => {
                if s.paused {
                    let mic = self.prefs.mic;
                    match s.start_segment(mic) {
                        Ok(()) => s.paused = false,
                        Err(e) => log::error!("resume: {e}"),
                    }
                } else {
                    s.stop_segment();
                    s.paused = true;
                }
            }
            BarAction::Stop => self.stop(ctx),
            BarAction::Camera(on) => {
                s.set_camera(on, ctx);
                self.prefs.save(&self.data_dir);
            }
            BarAction::Keys(on) => {
                s.set_keys(on);
                self.prefs.save(&self.data_dir);
            }
            BarAction::Mic => self.prefs.save(&self.data_dir),
        }
    }

    fn update_done(&mut self, ctx: &mut Ctx) {
        let Phase::Done { file, saving } = &mut self.phase else { return };
        if let Some(rx) = saving {
            match rx.try_recv() {
                Ok(Ok(Some(dest))) => {
                    let name = dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    ctx.hud.push(format!("Saved {name}"));
                    self.phase = Phase::Idle;
                    return;
                }
                Ok(Ok(None)) => *saving = None,
                Ok(Err(e)) => {
                    ctx.hud.push(e);
                    *saving = None;
                }
                Err(_) => {}
            }
        }
        let busy = saving.is_some();
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let builder = ViewportBuilder::default()
            .with_title("Utility Recording")
            .with_decorations(false)
            .with_always_on_top()
            .with_taskbar(false)
            .with_resizable(false)
            .with_inner_size([420.0, 64.0]);
        let mut act = 0;
        ctx.egui.show_viewport_immediate(ViewportId::from_hash_of("recording-done"), builder, |c, _| {
            egui::CentralPanel::default().show(c, |ui| {
                ui.horizontal_centered(|ui| {
                    ui.label(egui::RichText::new(&name).strong());
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add_enabled(!busy, egui::Button::new("Discard")).clicked() {
                            act = 2;
                        }
                        if ui.add_enabled(!busy, egui::Button::new("Save…")).clicked() {
                            act = 1;
                        }
                    });
                });
            });
            if c.input(|i| i.viewport().close_requested()) {
                act = 3;
            }
        });
        match act {
            1 => {
                let (tx, rx) = channel();
                let src = file.clone();
                std::thread::spawn(move || {
                    let _ = tx.send(save::save_as(&src));
                });
                *saving = Some(rx);
            }
            2 => self.cancel(),
            3 => self.phase = Phase::Idle, // closed: the file stays in the cache
            _ => {}
        }
    }
}

impl Feature for RecordingFeature {
    fn id(&self) -> &'static str {
        "recording"
    }
    fn title(&self) -> &'static str {
        "Screen recording"
    }
    fn shortcuts(&self) -> Vec<Shortcut> {
        vec![Shortcut {
            id: "record",
            label: "Record the screen (start/stop)",
            default: HotKey::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::Digit5),
        }]
    }
    fn set_enabled(&mut self, on: bool, ctx: &mut Ctx) {
        self.data_dir = ctx.data_dir.to_path_buf();
        self.prefs = Prefs::load(ctx.data_dir);
        if on {
            self.ffmpeg = ffmpeg::find_ffmpeg();
        } else {
            self.cancel();
        }
    }
    fn on_shortcut(&mut self, _id: &str, ctx: &mut Ctx) {
        match &self.phase {
            Phase::Idle | Phase::Done { saving: None, .. } => self.begin(ctx),
            Phase::Picking(_) => self.phase = Phase::Idle,
            Phase::Active(s) if !s.recording => {
                self.prefs.save(&self.data_dir);
                self.start_recording(ctx);
            }
            Phase::Active(_) => self.stop(ctx),
            _ => {}
        }
    }
    fn update(&mut self, ctx: &mut Ctx) {
        match &mut self.phase {
            Phase::Idle => {}
            Phase::Picking(p) => match p.show(ctx.egui) {
                None => {}
                Some(None) => self.phase = Phase::Idle,
                Some(Some(area)) => {
                    let monitors = std::mem::take(&mut p.monitors);
                    self.open_session(area, &monitors, ctx);
                }
            },
            Phase::Active(_) => self.update_active(ctx),
            Phase::Finishing(rx) => match rx.try_recv() {
                Ok(Ok(file)) => self.phase = Phase::Done { file, saving: None },
                Ok(Err(e)) => {
                    log::error!("screen recording: {e}");
                    ctx.hud.push(e);
                    self.phase = Phase::Idle;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.phase = Phase::Idle,
                Err(_) => {}
            },
            Phase::Done { .. } => self.update_done(ctx),
        }
    }
    fn settings_ui(&mut self, ui: &mut egui::Ui, _ctx: &mut Ctx) {
        match &self.ffmpeg {
            Some(p) => ui.label(format!("ffmpeg: {}", p.display())),
            None => ui.label("ffmpeg not found. Install it and add it to PATH."),
        };
    }
    fn shutdown(&mut self) {
        // Close the file properly; it stays in the cache folder.
        if let Phase::Active(s) = std::mem::replace(&mut self.phase, Phase::Idle) {
            let out = self.cache_dir().join(ffmpeg::file_name(
                SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
            ));
            let _ = s.finish(out).recv_timeout(Duration::from_secs(10));
        }
    }
}

// ---------------------------------------------------------------- session

struct Session {
    area: Rect,
    monitor: Rect,
    platform: Platform,
    ffmpeg: PathBuf,
    workdir: PathBuf,
    /// (camera, microphone) device names.
    devices: (Option<String>, Option<String>),
    recording: bool,
    paused: bool,
    child: Option<Child>,
    segments: Vec<PathBuf>,
    stoppers: Vec<JoinHandle<()>>,
    run_start: Option<Instant>,
    accum: Duration,
    camera: Option<Camera>,
    keyhook: Option<platform::KeyHook>,
    key_rx: Option<Receiver<Stroke>>,
    keylog: KeyLog,
    excluded: bool,
    cam_pos: Pos2,
}

/// Sends "q" so ffmpeg finalizes the MP4, then waits; kills after 8 s.
fn stop_child(mut c: Child) {
    if let Some(mut stdin) = c.stdin.take() {
        let _ = stdin.write_all(b"q");
        let _ = stdin.flush();
    }
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        if let Ok(Some(_)) = c.try_wait() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    log::warn!("ffmpeg didn't stop in time; killing it");
    let _ = c.kill();
    let _ = c.wait();
}

impl Session {
    fn elapsed(&self) -> Duration {
        self.accum + self.run_start.map_or(Duration::ZERO, |t| t.elapsed())
    }

    fn start_segment(&mut self, mic: bool) -> Result<(), String> {
        let n = self.segments.len();
        let out = self.workdir.join(format!("seg-{n}.mp4"));
        let display = platform::display();
        let mic = if mic { self.devices.1.as_deref() } else { None };
        let args = ffmpeg::encode_args(&ffmpeg::EncodeSpec { platform: self.platform, area: self.area, display: &display, mic, output: &out });
        log::info!("ffmpeg {}", args.join(" "));
        let log = std::fs::File::create(self.workdir.join(format!("ffmpeg-{n}.log"))).map_err(|e| e.to_string())?;
        let child = ffmpeg::command(&self.ffmpeg)
            .args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn()
            .map_err(|e| format!("ffmpeg: {e}"))?;
        self.child = Some(child);
        self.segments.push(out);
        self.run_start = Some(Instant::now());
        Ok(())
    }

    fn stop_segment(&mut self) {
        if let Some(t) = self.run_start.take() {
            self.accum += t.elapsed();
        }
        if let Some(c) = self.child.take() {
            self.stoppers.push(std::thread::spawn(move || stop_child(c)));
        }
    }

    fn set_camera(&mut self, on: bool, ctx: &mut Ctx) {
        if !on {
            self.camera = None;
            return;
        }
        let Some(dev) = self.devices.0.clone() else {
            ctx.hud.push("No camera found".into());
            return;
        };
        match Camera::start(&self.ffmpeg, self.platform, &dev) {
            Ok(c) => self.camera = Some(c),
            Err(e) => {
                log::error!("camera: {e}");
                ctx.hud.push("Camera unavailable".into());
            }
        }
    }

    fn set_keys(&mut self, on: bool) {
        self.keyhook = None;
        self.key_rx = None;
        if on {
            let (tx, rx) = channel();
            self.keyhook = platform::KeyHook::start(tx);
            self.key_rx = self.keyhook.as_ref().map(|_| rx);
        }
    }

    /// Stops capture and joins the segments into `out` on a worker thread.
    fn finish(mut self: Box<Self>, out: PathBuf) -> Receiver<Result<PathBuf, String>> {
        self.stop_segment();
        self.camera = None;
        self.keyhook = None;
        let (tx, rx) = channel();
        let (ffmpeg_path, workdir, segments, stoppers) =
            (self.ffmpeg.clone(), self.workdir.clone(), std::mem::take(&mut self.segments), std::mem::take(&mut self.stoppers));
        std::thread::spawn(move || {
            for s in stoppers {
                let _ = s.join();
            }
            let r = join_segments(&ffmpeg_path, &workdir, &segments, &out);
            if r.is_ok() {
                let _ = std::fs::remove_dir_all(&workdir);
            }
            let _ = tx.send(r);
        });
        rx
    }

    fn discard(mut self: Box<Self>) {
        self.stop_segment();
        let (workdir, stoppers) = (self.workdir.clone(), std::mem::take(&mut self.stoppers));
        std::thread::spawn(move || {
            for s in stoppers {
                let _ = s.join();
            }
            let _ = std::fs::remove_dir_all(workdir);
        });
    }
}

fn join_segments(ffmpeg_path: &Path, workdir: &Path, segments: &[PathBuf], out: &Path) -> Result<PathBuf, String> {
    let good: Vec<PathBuf> =
        segments.iter().filter(|p| std::fs::metadata(p).map(|m| m.len() > 0).unwrap_or(false)).cloned().collect();
    match good.len() {
        0 => Err("Nothing was recorded".into()),
        1 => {
            std::fs::rename(&good[0], out).map_err(|e| format!("Couldn't keep the recording: {e}"))?;
            Ok(out.to_path_buf())
        }
        _ => {
            let list = workdir.join("segments.txt");
            std::fs::write(&list, ffmpeg::concat_list(&good)).map_err(|e| e.to_string())?;
            let status = ffmpeg::command(ffmpeg_path)
                .args(ffmpeg::concat_args(&list, out))
                .stdin(Stdio::null())
                .status()
                .map_err(|e| e.to_string())?;
            if status.success() {
                Ok(out.to_path_buf())
            } else {
                Err("Couldn't join the recording".into())
            }
        }
    }
}

/// Where the bar goes, in physical pixels. When the OS can keep it out of the
/// video it sits near the bottom of the display; otherwise below or above the
/// area, falling back to the display's bottom.
fn bar_origin(excluded: bool, area: Rect, monitor: Rect, size: (i32, i32)) -> (i32, i32) {
    let x = (area.x + area.w / 2 - size.0 / 2).clamp(monitor.x, (monitor.right() - size.0).max(monitor.x));
    let bottom = monitor.bottom() - size.1 - 60;
    if excluded {
        return (x, bottom);
    }
    if area.bottom() + 12 + size.1 <= monitor.bottom() {
        (x, area.bottom() + 12)
    } else if area.y - 12 - size.1 >= monitor.y {
        (x, area.y - 12 - size.1)
    } else {
        (x, bottom)
    }
}

// ---------------------------------------------------------------- windows

enum BarAction {
    None,
    Record,
    Pause,
    Stop,
    Cancel,
    Camera(bool),
    Keys(bool),
    Mic,
}

fn overlay(title: &str, pos: Pos2, size: Vec2) -> ViewportBuilder {
    ViewportBuilder::default()
        .with_title(title)
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top()
        .with_taskbar(false)
        .with_resizable(false)
        .with_position(pos)
        .with_inner_size(size)
}

fn bar(egui: &egui::Context, pos: Pos2, s: &Session, prefs: &mut Prefs) -> BarAction {
    let mut action = BarAction::None;
    egui.show_viewport_immediate(ViewportId::from_hash_of("recording-bar"), overlay(BAR_TITLE, pos, BAR_SIZE), |ctx, _| {
        egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
            egui::Frame::popup(ui.style()).rounding(12.0).inner_margin(egui::Margin::symmetric(12.0, 8.0)).show(ui, |ui| {
                ui.set_min_size(ui.available_size());
                ui.horizontal_centered(|ui| {
                    if s.recording {
                        let dot = if s.paused { Color32::GRAY } else { Color32::from_rgb(230, 60, 50) };
                        ui.label(egui::RichText::new("●").color(dot));
                        ui.monospace(ffmpeg::elapsed_label(s.elapsed().as_secs()));
                        ui.separator();
                    }
                    if ui.toggle_value(&mut prefs.camera, "Camera").changed() {
                        action = BarAction::Camera(prefs.camera);
                    }
                    if ui.add_enabled(!s.recording, egui::SelectableLabel::new(prefs.mic, "Microphone")).clicked() {
                        prefs.mic = !prefs.mic;
                        action = BarAction::Mic;
                    }
                    if ui.toggle_value(&mut prefs.keys, "Keystrokes").changed() {
                        action = BarAction::Keys(prefs.keys);
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if s.recording {
                            if ui.button("Stop").clicked() {
                                action = BarAction::Stop;
                            }
                            if ui.button(if s.paused { "Resume" } else { "Pause" }).clicked() {
                                action = BarAction::Pause;
                            }
                        } else {
                            if ui.button("✕").on_hover_text("Cancel (Esc)").clicked() {
                                action = BarAction::Cancel;
                            }
                            let rec = egui::Button::new(egui::RichText::new("Record").color(Color32::WHITE).strong())
                                .fill(Color32::from_rgb(220, 50, 45));
                            if ui.add(rec).clicked() {
                                action = BarAction::Record;
                            }
                        }
                    });
                });
            });
        });
        if !s.recording && ctx.input(|i| i.key_pressed(egui::Key::Escape)) {
            action = BarAction::Cancel;
        }
    });
    action
}

fn camera_bubble(egui: &egui::Context, pos: Pos2, tex: Option<&egui::TextureHandle>) {
    let size = Vec2::splat(CAMERA_PT);
    egui.show_viewport_immediate(ViewportId::from_hash_of("recording-camera"), overlay("Utility Camera", pos, size), |ctx, _| {
        egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
            let (rect, resp) = ui.allocate_exact_size(size, egui::Sense::drag());
            if resp.drag_started() {
                ctx.send_viewport_cmd(ViewportCommand::StartDrag);
            }
            let r = CAMERA_PT / 2.0 - 2.0;
            let inner = rect.shrink(2.0);
            match tex {
                Some(t) => {
                    egui::Image::new((t.id(), inner.size())).rounding(r).paint_at(ui, inner);
                }
                None => {
                    ui.painter().circle_filled(rect.center(), r, Color32::from_gray(30));
                }
            }
            ui.painter().circle_stroke(rect.center(), r, egui::Stroke::new(3.0_f32, Color32::WHITE));
        });
    });
}

fn key_pill(egui: &egui::Context, pos: Pos2, text: &str) {
    let builder = overlay("Utility Keystrokes", pos, PILL_SIZE).with_mouse_passthrough(true);
    egui.show_viewport_immediate(ViewportId::from_hash_of("recording-keys"), builder, |ctx, _| {
        egui::CentralPanel::default().frame(egui::Frame::none()).show(ctx, |ui| {
            let full = ui.max_rect();
            let galley = ui.painter().layout_no_wrap(text.to_string(), egui::FontId::proportional(24.0), Color32::WHITE);
            let size = galley.size() + Vec2::new(36.0, 18.0);
            let rect = egui::Rect::from_center_size(full.center(), size.min(full.size()));
            ui.painter().rect_filled(rect, rect.height() / 2.0, Color32::from_black_alpha(200));
            ui.painter().galley(rect.center() - galley.size() / 2.0, galley, Color32::WHITE);
        });
    });
}

// ---------------------------------------------------------------- picker

struct Picker {
    monitors: Vec<Rect>,
    /// Other apps' windows, top to bottom.
    windows: Vec<Rect>,
    virt: Rect,
    drag_from: Option<(i32, i32)>,
    window_mode: bool,
    frames: u32,
}

impl Picker {
    /// None while picking, Some(None) when cancelled, Some(Some(area)) when done.
    fn show(&mut self, egui: &egui::Context) -> Option<Option<Rect>> {
        let ppp = egui.pixels_per_point();
        let v = self.virt;
        let builder = overlay(
            "Utility Recording Area",
            Pos2::new(v.x as f32 / ppp, v.y as f32 / ppp),
            Vec2::new(v.w as f32 / ppp, v.h as f32 / ppp),
        );
        egui.show_viewport_immediate(ViewportId::from_hash_of("recording-picker"), builder, |ctx, _| {
            if self.frames == 0 {
                ctx.send_viewport_cmd(ViewportCommand::Focus);
            }
            self.frames += 1;
            ctx.set_cursor_icon(egui::CursorIcon::Crosshair);
            let vppp = ctx.pixels_per_point();
            let origin = ctx
                .input(|i| i.viewport().inner_rect)
                .map(|r| r.min)
                .unwrap_or(Pos2::new(v.x as f32 / vppp, v.y as f32 / vppp));
            let to_phys = |p: Pos2| (((origin.x + p.x) * vppp).round() as i32, ((origin.y + p.y) * vppp).round() as i32);
            let to_local = |r: Rect| {
                egui::Rect::from_min_size(
                    Pos2::new(r.x as f32 / vppp - origin.x, r.y as f32 / vppp - origin.y),
                    Vec2::new(r.w as f32 / vppp, r.h as f32 / vppp),
                )
            };
            let (pointer, pressed, released, esc, enter, space, close) = ctx.input(|i| {
                (
                    i.pointer.hover_pos(),
                    i.pointer.primary_pressed(),
                    i.pointer.primary_released(),
                    i.key_pressed(egui::Key::Escape),
                    i.key_pressed(egui::Key::Enter),
                    i.key_pressed(egui::Key::Space),
                    i.viewport().close_requested(),
                )
            });
            if esc || close {
                return Some(None);
            }
            if space {
                self.window_mode = !self.window_mode;
                self.drag_from = None;
            }
            let p = pointer.map(to_phys);
            let here = p.unwrap_or((v.x + v.w / 2, v.y + v.h / 2));
            let monitor = geom::monitor_at(&self.monitors, here);
            if enter {
                return Some(monitor);
            }
            let mut sel = None;
            if self.window_mode {
                sel = p.and_then(|p| geom::window_at(&self.windows, p)).and_then(|w| w.intersect(&v));
                if released {
                    return Some(sel.or(monitor));
                }
            } else {
                if pressed {
                    self.drag_from = p;
                }
                if let (Some(a), Some(b)) = (self.drag_from, p) {
                    let r = Rect::from_corners(a, b);
                    if r.w >= 4 && r.h >= 4 {
                        sel = Some(r);
                    }
                }
                if released {
                    self.drag_from = None;
                    return Some(sel.or(monitor));
                }
            }

            let painter = ctx.layer_painter(egui::LayerId::new(egui::Order::Foreground, egui::Id::new("recording-picker")));
            let screen = ctx.screen_rect();
            let dim = Color32::from_black_alpha(110);
            match sel.map(to_local) {
                Some(s) => {
                    painter.rect_filled(egui::Rect::from_min_max(screen.min, Pos2::new(screen.max.x, s.min.y)), 0.0, dim);
                    painter.rect_filled(egui::Rect::from_min_max(Pos2::new(screen.min.x, s.max.y), screen.max), 0.0, dim);
                    painter.rect_filled(egui::Rect::from_min_max(Pos2::new(screen.min.x, s.min.y), Pos2::new(s.min.x, s.max.y)), 0.0, dim);
                    painter.rect_filled(egui::Rect::from_min_max(Pos2::new(s.max.x, s.min.y), Pos2::new(screen.max.x, s.max.y)), 0.0, dim);
                    let color = if self.window_mode { Color32::from_rgb(80, 160, 255) } else { Color32::WHITE };
                    painter.rect_stroke(s, 0.0, egui::Stroke::new(1.5_f32, color));
                    if let Some(r) = sel {
                        let even = r.even();
                        painter.text(
                            s.right_bottom() + Vec2::new(-4.0, 6.0),
                            egui::Align2::RIGHT_TOP,
                            format!("{} × {}", even.w, even.h),
                            egui::FontId::monospace(13.0),
                            Color32::WHITE,
                        );
                    }
                }
                None => {
                    painter.rect_filled(screen, 0.0, dim);
                }
            }
            if let Some(m) = monitor.map(to_local) {
                let hint = if self.window_mode {
                    "Click a window · Space for an area · Esc to cancel"
                } else {
                    "Drag an area · Space for a window · Click or Return for the full screen · Esc to cancel"
                };
                let galley = painter.layout_no_wrap(hint.into(), egui::FontId::proportional(15.0), Color32::WHITE);
                let rect = egui::Rect::from_center_size(Pos2::new(m.center().x, m.min.y + 48.0), galley.size() + Vec2::new(28.0, 14.0));
                painter.rect_filled(rect, rect.height() / 2.0, Color32::from_black_alpha(180));
                painter.galley(rect.center() - galley.size() / 2.0, galley, Color32::WHITE);
            }
            ctx.request_repaint();
            None
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_placement() {
        let mon = Rect::new(0, 0, 1920, 1080);
        let size = (500, 52);
        // excluded from capture: bottom of the display
        assert_eq!(bar_origin(true, Rect::new(100, 100, 400, 300), mon, size), (50, 1080 - 52 - 60));
        // X11: below the area when it fits
        assert_eq!(bar_origin(false, Rect::new(700, 100, 400, 300), mon, size), (650, 412));
        // above it when not
        assert_eq!(bar_origin(false, Rect::new(700, 600, 400, 470), mon, size), (650, 536));
        // full screen: bottom of the display (it will be in the video)
        assert_eq!(bar_origin(false, mon, mon, size), (710, 968));
    }
}
