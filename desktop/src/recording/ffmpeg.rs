//! Everything that talks to the `ffmpeg` binary: finding it, building
//! argument lists for capture, camera preview and concatenation, and parsing
//! DirectShow device lists.

use super::geom::Rect;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Windows,
    Linux,
}

impl Platform {
    pub fn current() -> Option<Self> {
        if cfg!(windows) {
            Some(Platform::Windows)
        } else if cfg!(target_os = "linux") {
            Some(Platform::Linux)
        } else {
            None
        }
    }
}

pub const FPS: u32 = 30;
/// Side of the square camera preview frames, in pixels.
pub const CAMERA_SIZE: u32 = 240;

pub fn find_ffmpeg() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(exe)).find(|p| p.is_file())
}

/// A Command for ffmpeg that never flashes a console window on Windows.
pub fn command(ffmpeg: &Path) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(ffmpeg);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    c
}

pub struct EncodeSpec<'a> {
    pub platform: Platform,
    pub area: Rect,
    /// X11 display, e.g. ":0". Ignored on Windows.
    pub display: &'a str,
    /// DirectShow audio device name on Windows, PulseAudio source on Linux.
    pub mic: Option<&'a str>,
    pub output: &'a Path,
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

/// Screen (+ optional microphone) to H.264/AAC MP4. Stop with "q" on stdin.
pub fn encode_args(spec: &EncodeSpec) -> Vec<String> {
    let a = spec.area.even();
    let mut v = s(&["-hide_banner", "-loglevel", "warning", "-y", "-thread_queue_size", "512"]);
    match spec.platform {
        Platform::Windows => {
            v.extend(s(&["-f", "gdigrab", "-framerate", &FPS.to_string(), "-draw_mouse", "1"]));
            v.extend(s(&["-offset_x", &a.x.to_string(), "-offset_y", &a.y.to_string()]));
            v.extend(s(&["-video_size", &format!("{}x{}", a.w, a.h), "-i", "desktop"]));
        }
        Platform::Linux => {
            v.extend(s(&["-f", "x11grab", "-framerate", &FPS.to_string(), "-draw_mouse", "1"]));
            v.extend(s(&["-video_size", &format!("{}x{}", a.w, a.h)]));
            v.extend(s(&["-i", &format!("{}+{},{}", spec.display, a.x, a.y)]));
        }
    }
    if let Some(mic) = spec.mic {
        v.extend(s(&["-thread_queue_size", "1024"]));
        match spec.platform {
            Platform::Windows => v.extend(s(&["-f", "dshow", "-i", &format!("audio={mic}")])),
            Platform::Linux => v.extend(s(&["-f", "pulse", "-i", mic])),
        }
    }
    v.extend(s(&["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p"]));
    if spec.mic.is_some() {
        v.extend(s(&["-c:a", "aac", "-b:a", "128k", "-ac", "1", "-ar", "48000"]));
    }
    v.extend(s(&["-movflags", "+faststart"]));
    v.push(spec.output.to_string_lossy().into_owned());
    v
}

/// Webcam to raw RGBA square frames on stdout, mirrored like a selfie view.
pub fn camera_args(platform: Platform, device: &str) -> Vec<String> {
    let mut v = s(&["-hide_banner", "-loglevel", "error"]);
    match platform {
        Platform::Windows => v.extend(s(&["-f", "dshow", "-i", &format!("video={device}")])),
        Platform::Linux => v.extend(s(&["-f", "v4l2", "-i", device])),
    }
    let n = CAMERA_SIZE;
    v.extend(s(&["-an", "-vf", &format!("crop=ih:ih,scale={n}:{n},hflip,fps=15")]));
    v.extend(s(&["-pix_fmt", "rgba", "-f", "rawvideo", "-"]));
    v
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn list_devices_args() -> Vec<String> {
    s(&["-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"])
}

/// Contents of a concat-demuxer list file.
pub fn concat_list(segments: &[PathBuf]) -> String {
    segments
        .iter()
        .map(|p| {
            let p = p.to_string_lossy().replace('\\', "/").replace('\'', "'\\''");
            format!("file '{p}'\n")
        })
        .collect()
}

pub fn concat_args(list: &Path, output: &Path) -> Vec<String> {
    let mut v = s(&["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i"]);
    v.push(list.to_string_lossy().into_owned());
    v.extend(s(&["-c", "copy", "-movflags", "+faststart"]));
    v.push(output.to_string_lossy().into_owned());
    v
}

/// (video, audio) device names from `ffmpeg -list_devices true -f dshow`.
/// Handles both the newer `"name" (video)` form and the older section form.
pub fn parse_dshow_devices(stderr: &str) -> (Vec<String>, Vec<String>) {
    let (mut video, mut audio) = (Vec::new(), Vec::new());
    let mut section: Option<bool> = None; // Some(true) = video
    for line in stderr.lines() {
        if line.contains("DirectShow video devices") {
            section = Some(true);
            continue;
        }
        if line.contains("DirectShow audio devices") {
            section = Some(false);
            continue;
        }
        if line.contains("Alternative name") {
            continue;
        }
        let Some(start) = line.find('"') else { continue };
        let Some(len) = line[start + 1..].find('"') else { continue };
        let name = line[start + 1..start + 1 + len].to_string();
        let rest = &line[start + 2 + len..];
        let is_video = if rest.contains("(video)") {
            Some(true)
        } else if rest.contains("(audio)") {
            Some(false)
        } else if rest.contains("(none)") {
            None
        } else {
            section
        };
        match is_video {
            Some(true) => video.push(name),
            Some(false) => audio.push(name),
            None => {}
        }
    }
    (video, audio)
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// "Screen Recording 2026-11-07 at 14.03.22.mp4" (UTC).
pub fn file_name(unix_secs: u64) -> String {
    let secs = unix_secs as i64;
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let t = secs.rem_euclid(86_400);
    format!("Screen Recording {y:04}-{m:02}-{d:02} at {:02}.{:02}.{:02}.mp4", t / 3600, t / 60 % 60, t % 60)
}

/// "0:07", "12:34", "1:02:03".
pub fn elapsed_label(secs: u64) -> String {
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, secs / 60 % 60, secs % 60)
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_encode_with_mic() {
        let out = PathBuf::from("C:/cache/seg-0.mp4");
        let args = encode_args(&EncodeSpec {
            platform: Platform::Windows,
            area: Rect::new(-1920, 10, 801, 601),
            display: ":0",
            mic: Some("Microphone (Realtek Audio)"),
            output: &out,
        });
        let j = args.join(" ");
        assert!(j.contains("-f gdigrab -framerate 30 -draw_mouse 1 -offset_x -1920 -offset_y 10 -video_size 800x600 -i desktop"), "{j}");
        assert!(j.contains("-f dshow -i audio=Microphone (Realtek Audio)"), "{j}");
        assert!(j.contains("-c:v libx264") && j.contains("-pix_fmt yuv420p") && j.contains("-c:a aac"), "{j}");
        assert_eq!(args.last().unwrap(), "C:/cache/seg-0.mp4");
        // the device name stays one argument
        assert!(args.iter().any(|a| a == "audio=Microphone (Realtek Audio)"));
    }

    #[test]
    fn linux_encode_without_mic() {
        let out = PathBuf::from("/tmp/a.mp4");
        let args = encode_args(&EncodeSpec {
            platform: Platform::Linux,
            area: Rect::new(100, 200, 1280, 720),
            display: ":1",
            mic: None,
            output: &out,
        });
        let j = args.join(" ");
        assert!(j.contains("-f x11grab -framerate 30 -draw_mouse 1 -video_size 1280x720 -i :1+100,200"), "{j}");
        assert!(!j.contains("pulse") && !j.contains("-c:a"), "{j}");
    }

    #[test]
    fn linux_mic_and_camera() {
        let out = PathBuf::from("/tmp/a.mp4");
        let spec = EncodeSpec { platform: Platform::Linux, area: Rect::new(0, 0, 10, 10), display: ":0", mic: Some("default"), output: &out };
        assert!(encode_args(&spec).join(" ").contains("-f pulse -i default"));
        let cam = camera_args(Platform::Linux, "/dev/video0").join(" ");
        assert!(cam.contains("-f v4l2 -i /dev/video0") && cam.contains("scale=240:240") && cam.ends_with("-f rawvideo -"), "{cam}");
        assert!(camera_args(Platform::Windows, "HD Webcam").iter().any(|a| a == "video=HD Webcam"));
    }

    #[test]
    fn concat() {
        let list = concat_list(&[PathBuf::from("C:\\a\\seg-0.mp4"), PathBuf::from("/x/it's.mp4")]);
        assert_eq!(list, "file 'C:/a/seg-0.mp4'\nfile '/x/it'\\''s.mp4'\n");
        let args = concat_args(Path::new("/l.txt"), Path::new("/o.mp4")).join(" ");
        assert!(args.contains("-f concat -safe 0 -i /l.txt -c copy"), "{args}");
    }

    #[test]
    fn dshow_parsing() {
        let new = r#"[dshow @ 0000] "Integrated Camera" (video)
[dshow @ 0000]   Alternative name "@device_pnp_\\?\usb#vid"
[dshow @ 0000] "Microphone Array (Realtek(R) Audio)" (audio)
[dshow @ 0000]   Alternative name "@device_cm_{33D9}"
[dshow @ 0000] "OBS Virtual Camera" (none)"#;
        let (v, a) = parse_dshow_devices(new);
        assert_eq!(v, vec!["Integrated Camera"]);
        assert_eq!(a, vec!["Microphone Array (Realtek(R) Audio)"]);
        let old = r#"[dshow @ 01] DirectShow video devices (some may be both video and audio devices)
[dshow @ 01]  "USB Cam"
[dshow @ 01] DirectShow audio devices
[dshow @ 01]  "Mic In""#;
        assert_eq!(parse_dshow_devices(old), (vec!["USB Cam".into()], vec!["Mic In".into()]));
    }

    #[test]
    fn names_and_times() {
        assert_eq!(file_name(0), "Screen Recording 1970-01-01 at 00.00.00.mp4");
        assert_eq!(file_name(951_782_400), "Screen Recording 2000-02-29 at 00.00.00.mp4");
        assert_eq!(file_name(1_700_000_000), "Screen Recording 2023-11-14 at 22.13.20.mp4");
        assert_eq!(elapsed_label(7), "0:07");
        assert_eq!(elapsed_label(754), "12:34");
        assert_eq!(elapsed_label(3723), "1:02:03");
    }
}
