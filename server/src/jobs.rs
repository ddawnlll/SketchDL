use crate::db::now;
use crate::media;
use crate::proc::{LineReader, Tail, isolate_process_group, kill_group, run_capture};
use crate::state::AppState;
use crate::ytdlp::{
    self, Inspection, MAX_JSON_BYTES, ProgressTracker, classify_error, parse_inspection,
    parse_progress, progress_template_arg,
};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;

fn access_x(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

pub async fn inspect_video(
    state: &AppState,
    expected_id: &str,
    canonical: &str,
) -> Result<Inspection, (String, String)> {
    if !access_x(&state.cfg.ytdlp) {
        return Err((
            "EXTRACTOR_MISSING".into(),
            "yt-dlp is not executable.".into(),
        ));
    }
    let mut c = base_prefix(&state.cfg);
    c.arg("--skip-download")
        .arg("--dump-single-json")
        .arg("--socket-timeout")
        .arg("15")
        .arg("--retries")
        .arg("2")
        .arg(canonical);
    let cap = run_capture(
        &mut c,
        Duration::from_secs(state.cfg.inspect_timeout.max(1)),
        MAX_JSON_BYTES,
    )
    .await;
    if let Some(e) = cap.spawn_error {
        return Err(("EXTRACTOR_MISSING".into(), e));
    }
    if cap.timed_out {
        return Err((
            "TIMEOUT".into(),
            "YouTube did not answer in time. Try again in a moment.".into(),
        ));
    }
    if cap.too_large {
        return Err((
            "METADATA_TOO_LARGE".into(),
            "YouTube returned more metadata than this server accepts.".into(),
        ));
    }
    if cap.code != Some(0) {
        let (code, detail) = classify_error(&cap.stderr_tail);
        return Err((
            if code.is_empty() {
                "INSPECT_FAILED".into()
            } else {
                code
            },
            if detail.is_empty() {
                "yt-dlp could not inspect this video.".into()
            } else {
                detail
            },
        ));
    }
    match parse_inspection(&cap.stdout, expected_id) {
        Some(i) => Ok(i),
        None => Err((
            "BAD_METADATA".into(),
            "YouTube returned metadata that did not match the requested video.".into(),
        )),
    }
}

fn base_prefix(cfg: &crate::config::Config) -> Command {
    let mut c = Command::new(&cfg.ytdlp);
    c.arg("--ignore-config");
    if let Some(p) = &cfg.ejs_parent {
        c.arg("--plugin-dirs").arg(p);
        c.env("PYTHONPATH", p);
    } else {
        c.arg("--no-plugin-dirs");
    }
    if let Some(home) = &cfg.bgutil_home {
        c.arg("--extractor-args")
            .arg(format!("youtubepot-bgutilscript:server_home={home}"));
        c.arg("--extractor-args")
            .arg("youtube:fetch_pot=always;player_client=mweb,tv,web_safari");
    }
    c.arg("--no-playlist");
    c.arg("--js-runtimes").arg(format!("deno:{}", cfg.deno));
    c
}

pub fn spawn_job(state: Arc<AppState>, id: String) {
    tokio::spawn(async move {
        run_job(state, id).await;
    });
}

async fn run_job(state: Arc<AppState>, id: String) {
    let permit = state.permits.acquire().await;
    if permit.is_err() {
        return;
    }
    let Some(job) = state.db.find_job(&id) else {
        return;
    };
    if job.state != "QUEUED" || state.is_cancelled(&id) {
        cleanup(&state, &id);
        state.publish_current(&id);
        return;
    }
    let start_now = now();
    if !state
        .db
        .transition(&id, "QUEUED", "DOWNLOADING", start_now, Some("START"))
    {
        return;
    }
    state.publish_current(&id);

    let jdir = state.job_dir(&id);
    let tmp = jdir.join("tmp");
    let _ = std::fs::remove_dir_all(&jdir);
    if std::fs::create_dir_all(&tmp).is_err() {
        fail(
            &state,
            &id,
            "STORAGE",
            "Could not create the job directory.",
        );
        return;
    }
    if state.cfg.min_free_bytes > 0 && state.free_bytes() < state.cfg.min_free_bytes {
        fail(
            &state,
            &id,
            "DISK_FULL",
            "Not enough free disk space to start this download.",
        );
        return;
    }
    if state.is_cancelled(&id) {
        cleanup(&state, &id);
        state.publish_current(&id);
        return;
    }

    let format_id = job.format_id.as_deref().unwrap_or("");
    if !ytdlp::valid_format_id(format_id) {
        fail(
            &state,
            &id,
            "BAD_FORMAT",
            "The selected format is not valid.",
        );
        return;
    }
    let expected = if format_id.contains('+') { 2 } else { 1 };
    let canonical = format!("https://www.youtube.com/watch?v={}", job.video_id);
    let mut c = base_prefix(&state.cfg);
    c.arg("--newline")
        .arg("--progress")
        .arg("--progress-delta")
        .arg("0.2")
        .arg("--progress-template")
        .arg(progress_template_arg())
        .arg("-f")
        .arg(format_id)
        .arg("--merge-output-format")
        .arg("mp4")
        .arg("--ffmpeg-location")
        .arg(&state.cfg.ffmpeg)
        .arg("--paths")
        .arg(format!("home:{}", jdir.display()))
        .arg("--paths")
        .arg(format!("temp:{}", tmp.display()))
        .arg("-o")
        .arg("%(id)s.%(ext)s")
        .arg("--max-filesize")
        .arg(state.cfg.max_download_bytes.to_string())
        .arg("--print")
        .arg("after_move:filepath")
        .arg("--socket-timeout")
        .arg("15")
        .arg("--retries")
        .arg("3")
        .arg("--concurrent-fragments")
        .arg(state.cfg.concurrent_fragments.to_string())
        .arg(&canonical)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    isolate_process_group(&mut c);

    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => {
            fail(
                &state,
                &id,
                "EXTRACTOR_MISSING",
                &format!("yt-dlp could not be started: {e}"),
            );
            return;
        }
    };
    let child_pid = child.id().unwrap_or(0);
    let worker_pid = std::process::id() as i64;
    state
        .db
        .set_worker(&id, worker_pid, Some(child_pid as i64), now());
    state.publish_current(&id);

    let mut out = LineReader::new(child.stdout.take().expect("stdout piped"));
    let mut err = LineReader::new(child.stderr.take().expect("stderr piped"));
    let mut tracker = ProgressTracker::new(expected);
    let mut err_tail = Tail::new(16 * 1024);
    let mut last_path: Option<PathBuf> = None;
    let deadline =
        tokio::time::Instant::now() + Duration::from_secs(state.cfg.download_timeout.max(1));
    let mut out_open = true;
    let mut err_open = true;
    let mut timed_out = false;
    let mut last_db = tokio::time::Instant::now() - Duration::from_secs(1);
    let mut last_bcast = tokio::time::Instant::now() - Duration::from_secs(1);

    while out_open || err_open {
        tokio::select! {
            line = out.next_line(), if out_open => {
                match line {
                    Ok(Some(l)) => {
                        if let Some(p) = parse_progress(&l) {
                            tracker.feed(&p);
                            let nowi = tokio::time::Instant::now();
                            let stage = tracker.stage();
                            if nowi.duration_since(last_bcast) >= Duration::from_millis(200) {
                                let total = tracker.total();
                                let speed = tracker.speed;
                                let eta = tracker.eta;
                                if nowi.duration_since(last_db) >= Duration::from_millis(500) {
                                    state.db.update_progress(
                                        &id, worker_pid, stage, tracker.downloaded(),
                                        total, speed, eta, now(),
                                    );
                                    last_db = nowi;
                                }
                                state.events.publish(&id, crate::views::sse_values(
                                    &id, "DOWNLOADING", stage, tracker.downloaded(),
                                    total, speed, eta,
                                ));
                                last_bcast = nowi;
                            }
                        } else if let Some(p) = output_path(&l, &jdir) {
                            last_path = Some(p);
                        }
                    }
                    Ok(None) => out_open = false,
                    Err(_) => out_open = false,
                }
            }
            line = err.next_line(), if err_open => {
                match line {
                    Ok(Some(l)) => err_tail.push_str(&l),
                    Ok(None) => err_open = false,
                    Err(_) => err_open = false,
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                timed_out = true;
                kill_group(child_pid);
                break;
            }
        }
    }

    let status = match tokio::time::timeout(Duration::from_secs(5), child.wait()).await {
        Ok(Ok(s)) => Some(s),
        _ => {
            kill_group(child_pid);
            None
        }
    };
    let current = state.db.find_job(&id);
    if current.as_ref().is_some_and(|j| j.state == "CANCELLED") {
        cleanup(&state, &id);
        state.publish_current(&id);
        return;
    }
    if timed_out {
        fail(
            &state,
            &id,
            "TIMEOUT",
            "The download took too long and was stopped.",
        );
        return;
    }
    if !status
        .as_ref()
        .and_then(|s| s.code())
        .is_some_and(|c| c == 0)
    {
        let msg = err_tail.as_str();
        let (code, detail) = classify_error(&msg);
        fail(
            &state,
            &id,
            if code.is_empty() {
                "DOWNLOAD_FAILED"
            } else {
                &code
            },
            if detail.is_empty() {
                "yt-dlp exited without a usable error message."
            } else {
                &detail
            },
        );
        return;
    }

    let moved = match last_path.filter(|p| p.is_file()) {
        Some(p) => p,
        None => match find_mp4(&jdir) {
            Some(p) => p,
            None => {
                fail(
                    &state,
                    &id,
                    "MISSING_OUTPUT",
                    "yt-dlp reported success but no output file was found.",
                );
                return;
            }
        },
    };
    let size = std::fs::metadata(&moved)
        .map(|m| m.len() as i64)
        .unwrap_or(0);
    if size <= 0 {
        fail(&state, &id, "EMPTY_OUTPUT", "The downloaded file is empty.");
        return;
    }
    if size > state.cfg.max_download_bytes {
        fail(
            &state,
            &id,
            "TOO_LARGE",
            "The downloaded file exceeded the configured size limit.",
        );
        return;
    }

    let t = now();
    if !state
        .db
        .transition(&id, "DOWNLOADING", "VERIFYING", t, Some("VERIFY"))
    {
        cleanup(&state, &id);
        state.publish_current(&id);
        return;
    }
    state.db.set_stage(&id, "verifying", t);
    state.publish_current(&id);

    let verified = media::verify_mp4(
        &state.cfg.ffprobe,
        &moved.to_string_lossy(),
        Duration::from_secs(30),
    )
    .await;
    match verified {
        Ok(_) => {}
        Err(e) => {
            fail(&state, &id, "VERIFICATION_FAILED", &e);
            return;
        }
    }

    let complete = state.complete_path(&id);
    if let Some(parent) = complete.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::remove_file(&complete);
    if std::fs::rename(&moved, &complete).is_err() {
        if std::fs::copy(&moved, &complete).is_err() {
            fail(
                &state,
                &id,
                "PUBLISH_FAILED",
                "Could not move the verified file into place.",
            );
            return;
        }
        let _ = std::fs::remove_file(&moved);
    }
    if let Ok(f) = std::fs::File::open(&complete) {
        let _ = f.sync_all();
    }
    if let Some(parent) = complete.parent() {
        if let Ok(d) = std::fs::File::open(parent) {
            let _ = d.sync_all();
        }
    }

    let expires = now() + state.cfg.retain_hours.max(1) * 3600;
    if !state.db.set_ready(&id, size, expires, now()) {
        // Lost a race with cancel/delete.
        let _ = std::fs::remove_file(&complete);
        cleanup(&state, &id);
        state.publish_current(&id);
        return;
    }
    cleanup(&state, &id);
    state.clear_cancelled(&id);
    state.publish_current(&id);
}

fn output_path(line: &str, jdir: &Path) -> Option<PathBuf> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    let p = Path::new(line);
    if p.is_absolute() && p.starts_with(jdir) && p.extension().is_some_and(|e| e == "mp4") {
        return Some(p.to_path_buf());
    }
    None
}

fn find_mp4(dir: &Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut subdirs = Vec::new();
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_file() && p.extension().is_some_and(|e| e == "mp4") {
            return Some(p);
        }
        if p.is_dir() {
            subdirs.push(p);
        }
    }
    for d in subdirs {
        if let Ok(entries) = std::fs::read_dir(&d) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file() && p.extension().is_some_and(|e| e == "mp4") {
                    return Some(p);
                }
            }
        }
    }
    None
}

fn cleanup(state: &AppState, id: &str) {
    let _ = std::fs::remove_dir_all(state.job_dir(id));
}

fn fail(state: &AppState, id: &str, code: &str, detail: &str) {
    state.db.set_failure(id, code, detail, now());
    cleanup(state, id);
    state.publish_current(id);
}
