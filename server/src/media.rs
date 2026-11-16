use crate::proc::{Captured, run_capture};
use serde_json::Value;
use std::time::Duration;
use tokio::process::Command;

pub async fn verify_mp4(ffprobe: &str, path: &str, timeout: Duration) -> Result<(), String> {
    let mut cmd = Command::new(ffprobe);
    cmd.arg("-v")
        .arg("error")
        .arg("-print_format")
        .arg("json")
        .arg("-show_format")
        .arg("-show_streams")
        .arg(path);
    let cap: Captured = run_capture(&mut cmd, timeout, 2 * 1024 * 1024).await;
    if let Some(e) = cap.spawn_error {
        return Err(format!("ffprobe spawn failed: {e}"));
    }
    if cap.timed_out {
        return Err("ffprobe timed out".into());
    }
    if cap.too_large {
        return Err("ffprobe output too large".into());
    }
    if cap.code != Some(0) {
        return Err("ffprobe failed".into());
    }
    let root: Value = serde_json::from_slice(&cap.stdout).map_err(|_| "ffprobe JSON invalid")?;
    let format_name = root
        .get("format")
        .and_then(|f| f.get("format_name"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if !format_name.split(',').any(|s| s.trim() == "mp4") {
        return Err(format!("not an MP4 container ({format_name})"));
    }
    let mut width = 0;
    let mut height = 0;
    let mut has_h264 = false;
    let mut has_audio = false;
    let mut has_aac = false;
    if let Some(streams) = root.get("streams").and_then(Value::as_array) {
        for s in streams {
            let ctype = s.get("codec_type").and_then(Value::as_str).unwrap_or("");
            let codec = s.get("codec_name").and_then(Value::as_str).unwrap_or("");
            if ctype == "video" {
                if codec == "h264" {
                    has_h264 = true;
                }
                width = s.get("width").and_then(Value::as_i64).unwrap_or(0);
                height = s.get("height").and_then(Value::as_i64).unwrap_or(0);
            } else if ctype == "audio" {
                has_audio = true;
                if codec == "aac" {
                    has_aac = true;
                }
            }
        }
    }
    if !has_h264 {
        return Err("video stream is not H.264".into());
    }
    if has_audio && !has_aac {
        return Err("audio stream is not AAC".into());
    }
    let duration = root
        .get("format")
        .and_then(|f| f.get("duration"))
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<f64>().ok());
    if width <= 0 || height <= 0 {
        return Err("video dimensions are missing".into());
    }
    if duration.is_none_or(|d| d <= 0.0) {
        return Err("video duration is missing".into());
    }
    Ok(())
}
