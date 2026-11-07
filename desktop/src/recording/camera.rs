//! Live webcam frames for the bubble: a second ffmpeg process writes raw
//! RGBA squares to stdout and a reader thread keeps the newest one.

use super::ffmpeg::{self, Platform, CAMERA_SIZE};
use std::io::Read;
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};

pub struct Camera {
    child: Child,
    latest: Arc<Mutex<Option<Vec<u8>>>>,
}

impl Camera {
    pub fn start(ffmpeg_path: &Path, platform: Platform, device: &str) -> std::io::Result<Camera> {
        let mut child = ffmpeg::command(ffmpeg_path)
            .args(ffmpeg::camera_args(platform, device))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let mut out = child.stdout.take().ok_or_else(|| std::io::Error::other("no stdout"))?;
        let latest = Arc::new(Mutex::new(None));
        let sink = latest.clone();
        std::thread::spawn(move || {
            let mut buf = vec![0u8; (CAMERA_SIZE * CAMERA_SIZE * 4) as usize];
            while out.read_exact(&mut buf).is_ok() {
                if let Ok(mut g) = sink.lock() {
                    *g = Some(buf.clone());
                }
            }
        });
        Ok(Camera { child, latest })
    }

    pub fn take_frame(&self) -> Option<Vec<u8>> {
        self.latest.lock().ok()?.take()
    }

    pub fn exited(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(Some(_)))
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
