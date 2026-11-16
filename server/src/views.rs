use crate::db::Job;
use crate::ytdlp::QualityOption;

pub const CSP: &str = "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'none'; font-src 'self'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

const LOGO_SVG: &str = "<svg class=\"word-sketch\" viewBox=\"0 0 48 48\" width=\"32\" height=\"32\" aria-hidden=\"true\"><path d=\"M6 30 L26 10 L30 14 L12 34 Z\"/><path d=\"M26 10 L34 6 L40 12 L33 20\"/><path d=\"M8 40 Q24 36 42 39\"/></svg>";
const PENCIL_SVG: &str = "<svg class=\"hero\" viewBox=\"0 0 400 170\" role=\"img\" aria-label=\"A pencil sketching a download arrow into a tray\"><path class=\"drawn-path\" d=\"M30 120 Q90 60 190 88 T360 70\"/><path class=\"drawn-path delay-1\" d=\"M150 44 L150 108 M132 92 L150 110 L168 92\"/><path class=\"drawn-accent\" d=\"M52 128 Q180 140 348 126\"/><path class=\"drawn-path delay-2\" d=\"M60 146 L340 144\"/><path class=\"drawn-moss\" d=\"M330 30 l8 -12 M338 38 l12 -6\"/></svg>";
const LOCK_SVG: &str = "<svg viewBox=\"0 0 48 48\" width=\"40\" height=\"40\" aria-hidden=\"true\"><path d=\"M14 22 v-6 a10 10 0 0 1 20 0 v6\"/><rect x=\"10\" y=\"22\" width=\"28\" height=\"20\" rx=\"4\"/><circle cx=\"24\" cy=\"30\" r=\"3\"/><path d=\"M24 33 v4\"/></svg>";

pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 16);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

pub fn fmt_bytes(n: i64) -> String {
    if n < 0 {
        return "unknown".into();
    }
    if n < 1024 {
        return format!("{n} B");
    }
    let units = ["KiB", "MiB", "GiB", "TiB"];
    let mut v = n as f64 / 1024.0;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{:.1} {}", v, units[i])
}

pub fn fmt_speed(n: i64) -> String {
    format!("{}/s", fmt_bytes(n))
}

pub fn fmt_eta(secs: i64) -> String {
    if secs < 0 {
        return String::new();
    }
    if secs >= 3600 {
        format!("{}h {:02}m left", secs / 3600, (secs % 3600) / 60)
    } else if secs >= 60 {
        format!("{}m {:02}s left", secs / 60, secs % 60)
    } else {
        format!("{}s left", secs)
    }
}

pub fn fmt_duration(secs: i64) -> String {
    if secs < 0 {
        return String::new();
    }
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs % 3600) / 60, secs % 60)
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

pub fn fmt_time(ts: i64) -> String {
    let days = ts.div_euclid(86_400);
    let sod = ts.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02} UTC",
        y,
        m,
        d,
        sod / 3600,
        (sod % 3600) / 60
    )
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn head(out: &mut String, title: &str, active: bool) {
    out.push_str("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    out.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    if active {
        out.push_str("<meta http-equiv=\"refresh\" content=\"3\">");
    }
    out.push_str("<title>");
    out.push_str(&esc(title));
    out.push_str("</title><link rel=\"stylesheet\" href=\"/assets/style.css\">");
    if active {
        out.push_str("<script src=\"/assets/progress.js\" defer></script>");
    }
    out.push_str("<meta name=\"color-scheme\" content=\"light\"></head><body>");
    out.push_str("<header class=\"site\"><a class=\"brand\" href=\"/\">");
    out.push_str(LOGO_SVG);
    out.push_str("<span>SketchDL</span></a><nav class=\"nav-links\"><a href=\"/jobs\">Jobs</a></nav></header><main>");
}

fn foot(out: &mut String) {
    out.push_str("</main><footer class=\"site\"><p>SketchDL &middot; server-rendered HTML &middot; your downloads stay on your own disk.</p></footer></body></html>");
}

pub fn login_page(error: Option<&str>) -> String {
    let mut out = String::with_capacity(4096);
    head(&mut out, "Log in - SketchDL", false);
    out.push_str(PENCIL_SVG);
    out.push_str("<h1>Welcome back.</h1><p class=\"lead\">This sketchbook is private. Log in to copy a video you own or are allowed to download.</p>");
    if let Some(msg) = error {
        out.push_str("<div class=\"notice error\"><h3>Could not log in.</h3><p>");
        out.push_str(&esc(msg));
        out.push_str("</p></div>");
    }
    out.push_str("<form class=\"card\" method=\"post\" action=\"/login\" autocomplete=\"off\">");
    out.push_str("<div class=\"field\"><label for=\"pw\">Owner password ");
    out.push_str(LOCK_SVG);
    out.push_str("</label><input id=\"pw\" name=\"password\" type=\"password\" autocomplete=\"current-password\" required minlength=\"12\" maxlength=\"1024\"></div>");
    out.push_str("<div class=\"field-hint\">Passwords are verified with Argon2id on the server. Several wrong tries pause login for a while.</div>");
    out.push_str("<div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Open my sketchbook</button></div></form>");
    foot(&mut out);
    out
}

pub fn home_page(csrf: &str, jobs: &[Job], error: Option<&str>) -> String {
    let mut out = String::with_capacity(8192);
    head(&mut out, "SketchDL - home", false);
    out.push_str("<h1>Paste a YouTube link.</h1><p class=\"lead\">SketchDL previews one video at a time and saves it as an MP4 you can download from here. Single videos only.</p>");
    if let Some(msg) = error {
        out.push_str("<div class=\"notice error\"><h3>That link did not work.</h3><p>");
        out.push_str(&esc(msg));
        out.push_str("</p></div>");
    }
    out.push_str("<form class=\"card\" method=\"post\" action=\"/inspect\" autocomplete=\"off\">");
    out.push_str("<input type=\"hidden\" name=\"csrf\" value=\"");
    out.push_str(csrf);
    out.push_str("\"><div class=\"field\"><label for=\"url\">Video URL</label>");
    out.push_str("<input id=\"url\" name=\"url\" type=\"url\" inputmode=\"url\" placeholder=\"https://www.youtube.com/watch?v=...\" required maxlength=\"2048\">");
    out.push_str("<div class=\"field-hint\">Accepted: youtube.com watch, shorts, and youtu.be links. The link is rebuilt canonically before anything runs.</div></div>");
    out.push_str("<div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Inspect video</button></div></form>");
    out.push_str("<h2>Recent downloads</h2>");
    if jobs.is_empty() {
        out.push_str("<p class=\"muted\">Nothing yet. Your first sketch will appear here.</p>");
    } else {
        job_list(&mut out, jobs, csrf);
    }
    foot(&mut out);
    out
}

pub fn state_class(state: &str) -> &'static str {
    match state {
        "READY" => "ready",
        "DOWNLOADING" => "downloading",
        "QUEUED" => "queued",
        "VERIFYING" => "verifying",
        "FAILED" => "failed",
        "CANCELLED" => "cancelled",
        "EXPIRED" => "expired",
        _ => "queued",
    }
}

pub fn state_label(state: &str) -> &'static str {
    match state {
        "READY" => "ready",
        "DOWNLOADING" => "downloading",
        "QUEUED" => "queued",
        "VERIFYING" => "checking",
        "FAILED" => "failed",
        "CANCELLED" => "cancelled",
        "EXPIRED" => "expired",
        _ => "queued",
    }
}

fn job_row(out: &mut String, job: &Job, csrf: &str) {
    out.push_str("<li class=\"job-row\"><a class=\"title\" href=\"/jobs/");
    out.push_str(&job.id);
    out.push_str("\">");
    out.push_str(&esc(job.title.as_deref().unwrap_or(&job.video_id)));
    out.push_str("</a> <span class=\"state ");
    out.push_str(state_class(&job.state));
    out.push_str("\">");
    out.push_str(state_label(&job.state));
    out.push_str("</span><div class=\"sub\"><span class=\"muted\">");
    out.push_str(&fmt_time(job.created_at));
    out.push_str("</span>");
    if let Some(n) = job.output_bytes {
        out.push_str(" &middot; ");
        out.push_str(&fmt_bytes(n));
    }
    out.push_str("</div><div class=\"actions\">");
    if job.state == "READY" {
        out.push_str("<a class=\"paper-button primary\" href=\"/downloads/");
        out.push_str(&job.id);
        out.push_str("\">Download MP4</a>");
    }
    if matches!(job.state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING") {
        action_form(
            out,
            &job.id,
            "cancel",
            csrf,
            "Cancel",
            "paper-button danger",
        );
    }
    if matches!(job.state.as_str(), "FAILED" | "CANCELLED") && job.retry_count < 3 {
        action_form(out, &job.id, "retry", csrf, "Retry", "paper-button");
    }
    action_form(out, &job.id, "delete", csrf, "Remove", "paper-button");
    out.push_str("</div></li>");
}

fn action_form(out: &mut String, id: &str, action: &str, csrf: &str, label: &str, class: &str) {
    out.push_str("<form class=\"inline\" method=\"post\" action=\"/jobs/");
    out.push_str(id);
    out.push('/');
    out.push_str(action);
    out.push_str("\"><input type=\"hidden\" name=\"csrf\" value=\"");
    out.push_str(csrf);
    out.push_str("\"><button class=\"");
    out.push_str(class);
    out.push_str("\" type=\"submit\">");
    out.push_str(label);
    out.push_str("</button></form>");
}

fn job_list(out: &mut String, jobs: &[Job], csrf: &str) {
    out.push_str("<ul class=\"job-list\">");
    for j in jobs {
        job_row(out, j, csrf);
    }
    out.push_str("</ul>");
}

pub fn inspect_page(
    csrf: &str,
    token: &str,
    title: &str,
    duration: Option<i64>,
    options: &[QualityOption],
    video_id: &str,
) -> String {
    let mut out = String::with_capacity(8192);
    head(&mut out, "Inspect - SketchDL", false);
    out.push_str("<h1>");
    out.push_str(&esc(title));
    out.push_str("</h1><p class=\"lead\"><a href=\"https://www.youtube.com/watch?v=");
    out.push_str(video_id);
    out.push_str("\">View on YouTube</a>");
    if let Some(d) = duration {
        out.push_str(" &middot; ");
        out.push_str(&fmt_duration(d));
    }
    out.push_str("</p><p class=\"muted\">Choose a quality. Only H.264 video with AAC audio (MP4-compatible) is listed; sizes are estimates from YouTube.</p>");
    out.push_str("<form class=\"card\" method=\"post\" action=\"/jobs\">");
    out.push_str("<input type=\"hidden\" name=\"csrf\" value=\"");
    out.push_str(csrf);
    out.push_str("\"><input type=\"hidden\" name=\"inspect\" value=\"");
    out.push_str(token);
    out.push_str("\"><fieldset class=\"fs-plain\"><legend class=\"muted\">Quality</legend><ul class=\"format-list\">");
    let default = options
        .iter()
        .position(|o| o.label == "720p")
        .or(if options.is_empty() { None } else { Some(0) });
    for (i, o) in options.iter().enumerate() {
        let label = &o.label;
        out.push_str(
            "<li><label class=\"format-row\"><input type=\"radio\" name=\"preset\" value=\"",
        );
        out.push_str(label);
        out.push('"');
        if default == Some(i) {
            out.push_str(" checked");
        }
        out.push_str("><span class=\"q\">");
        out.push_str(label);
        out.push_str("</span><span class=\"meta\">");
        out.push_str(if o.combined {
            "single file"
        } else {
            "H.264 + AAC"
        });
        out.push_str("</span><span class=\"size\">");
        if o.size_est >= 0 {
            out.push_str(&fmt_bytes(o.size_est));
        } else {
            out.push_str("size unknown");
        }
        out.push_str("</span></label></li>");
    }
    out.push_str("</ul></fieldset><div class=\"button-row mt\"><button class=\"paper-button primary\" type=\"submit\">Start download</button><a class=\"paper-button\" href=\"/\">Back</a></div>");
    out.push_str("<div class=\"field-hint\">This preview expires in a few minutes. The download is server-side; nothing is sent to your browser except the finished file.</div></form>");
    foot(&mut out);
    out
}

pub fn inspect_empty(csrf: &str, message: &str) -> String {
    let mut out = String::with_capacity(4096);
    head(&mut out, "Inspect - SketchDL", false);
    out.push_str("<h1>No compatible video found.</h1><div class=\"notice error\"><h3>FORMAT_UNAVAILABLE</h3><p>");
    out.push_str(&esc(message));
    out.push_str("</p></div><form class=\"card\" method=\"post\" action=\"/inspect\" autocomplete=\"off\"><input type=\"hidden\" name=\"csrf\" value=\"");
    out.push_str(csrf);
    out.push_str("\"><div class=\"field\"><label for=\"url\">Try another link</label><input id=\"url\" name=\"url\" type=\"url\" required maxlength=\"2048\"></div><div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Inspect video</button><a class=\"paper-button\" href=\"/\">Home</a></div></form>");
    foot(&mut out);
    out
}

pub fn inspect_error(csrf: &str, code: &str, detail: &str) -> String {
    let mut out = String::with_capacity(4096);
    head(&mut out, "Inspect - SketchDL", false);
    out.push_str("<h1>Could not inspect that video.</h1><div class=\"notice error\"><h3>");
    out.push_str(&esc(code));
    out.push_str("</h3><p>");
    out.push_str(&esc(detail));
    out.push_str("</p></div><form class=\"card\" method=\"post\" action=\"/inspect\" autocomplete=\"off\"><input type=\"hidden\" name=\"csrf\" value=\"");
    out.push_str(csrf);
    out.push_str("\"><div class=\"field\"><label for=\"url\">Try another link</label><input id=\"url\" name=\"url\" type=\"url\" required maxlength=\"2048\"></div><div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Inspect video</button><a class=\"paper-button\" href=\"/\">Home</a></div></form>");
    foot(&mut out);
    out
}

pub fn job_page(csrf: &str, job: &Job, facts: Option<&str>) -> String {
    let active = matches!(job.state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING");
    let mut out = String::with_capacity(8192);
    head(&mut out, "Job - SketchDL", active);
    out.push_str("<p class=\"muted\"><a href=\"/jobs\">&larr; all jobs</a></p><h1>");
    out.push_str(&esc(job.title.as_deref().unwrap_or(&job.video_id)));
    out.push_str("</h1><p class=\"lead\"><span class=\"state ");
    out.push_str(state_class(&job.state));
    out.push_str("\" id=\"state\">");
    out.push_str(state_label(&job.state));
    out.push_str("</span></p>");

    if job.state == "READY" {
        out.push_str("<svg class=\"checkmark drawn\" viewBox=\"0 0 60 60\" width=\"60\" height=\"60\" role=\"img\" aria-label=\"Download completed\"><path d=\"M12 32 L24 44 L50 18\"/></svg>");
        out.push_str("<div class=\"progress-meta\"><span>MP4");
        if let Some(n) = job.output_bytes {
            out.push_str(" &middot; ");
            out.push_str(&fmt_bytes(n));
        }
        if let Some(t) = job.expires_at {
            out.push_str(" &middot; expires ");
            out.push_str(&fmt_time(t));
        }
        out.push_str("</span>");
        if let Some(f) = facts {
            if !f.is_empty() {
                out.push_str("<span>");
                out.push_str(&esc(f));
                out.push_str("</span>");
            }
        }
        out.push_str("</div><div class=\"button-row mt\"><a class=\"paper-button primary\" href=\"/downloads/");
        out.push_str(&job.id);
        out.push_str(
            "\">Download MP4</a><a class=\"paper-button\" href=\"/jobs\">All jobs</a></div>",
        );
    } else if matches!(job.state.as_str(), "FAILED" | "CANCELLED" | "EXPIRED") {
        out.push_str("<div class=\"notice error\"><h3>");
        if job.state == "EXPIRED" {
            out.push_str("This download expired.");
        } else if job.state == "CANCELLED" {
            out.push_str("Download cancelled.");
        } else {
            out.push_str("Something went wrong.");
        }
        out.push_str("</h3>");
        if let Some(code) = &job.error_code {
            out.push_str("<p><span class=\"code\">");
            out.push_str(&esc(code));
            out.push_str("</span></p>");
        }
        if let Some(detail) = &job.error_detail {
            out.push_str("<p class=\"muted small\">");
            out.push_str(&esc(detail));
            out.push_str("</p>");
        }
        out.push_str("</div><div class=\"button-row\">");
        if job.retry_count < 3 {
            out.push_str("<form class=\"inline\" method=\"post\" action=\"/jobs/");
            out.push_str(&job.id);
            out.push_str("/retry\"><input type=\"hidden\" name=\"csrf\" value=\"");
            out.push_str(csrf);
            out.push_str("\"><button class=\"paper-button primary\" type=\"submit\">Try again</button></form>");
        }
        out.push_str("<a class=\"paper-button\" href=\"/\">New video</a></div>");
    } else {
        out.push_str("<div class=\"progress-wrap\" id=\"job-progress\" data-job=\"");
        out.push_str(&job.id);
        out.push_str("\">");
        if job.state == "QUEUED" {
            out.push_str("<p class=\"stage-label\" id=\"stage\">Waiting its turn</p><div class=\"indeterminate\" aria-label=\"Waiting\"><span class=\"nip\"></span></div>");
        } else if job.state == "VERIFYING" {
            out.push_str("<p class=\"stage-label\" id=\"stage\">Checking the file</p><div class=\"indeterminate\" aria-label=\"Verifying\"><span class=\"nip\"></span></div>");
        } else if let Some(total) = job.total_bytes {
            if total > 0 && job.downloaded_bytes >= 0 {
                let pct = ((job.downloaded_bytes.saturating_mul(100)) / total).min(100);
                out.push_str("<progress id=\"bar\" max=\"100\" value=\"");
                out.push_str(&pct.to_string());
                out.push_str("\" aria-label=\"Download progress\">");
                out.push_str(&pct.to_string());
                out.push_str(
                    "% complete</progress><div class=\"progress-meta\"><span id=\"bytes\">",
                );
                out.push_str(&fmt_bytes(job.downloaded_bytes));
                out.push_str(" of ");
                out.push_str(&fmt_bytes(total));
                out.push_str("</span><span id=\"speed\">");
                if let Some(s) = job.speed_bps {
                    out.push_str(&fmt_speed(s));
                }
                out.push_str("</span><span id=\"eta\">");
                if let Some(e) = job.eta_seconds {
                    out.push_str(&fmt_eta(e));
                }
                out.push_str("</span></div>");
            } else {
                out.push_str("<p class=\"stage-label\" id=\"stage\">Downloading</p><div class=\"indeterminate\" aria-label=\"Downloading\"><span class=\"nip\"></span></div><div class=\"progress-meta\"><span id=\"bytes\">");
                out.push_str(&fmt_bytes(job.downloaded_bytes));
                out.push_str(" so far</span><span id=\"speed\">");
                if let Some(s) = job.speed_bps {
                    out.push_str(&fmt_speed(s));
                }
                out.push_str("</span></div>");
            }
        } else {
            out.push_str("<p class=\"stage-label\" id=\"stage\">Downloading</p><div class=\"indeterminate\" aria-label=\"Downloading, total size unknown\"><span class=\"nip\"></span></div><div class=\"progress-meta\"><span id=\"bytes\">");
            out.push_str(&fmt_bytes(job.downloaded_bytes));
            out.push_str(" so far</span><span id=\"speed\">");
            if let Some(s) = job.speed_bps {
                out.push_str(&fmt_speed(s));
            }
            out.push_str("</span></div>");
        }
        out.push_str("</div><p class=\"muted small\">Live progress arrives from the server over Server-Sent Events. The page also refreshes every 3 seconds as a fallback.</p>");
        action_form(
            &mut out,
            &job.id,
            "cancel",
            csrf,
            "Cancel download",
            "paper-button danger",
        );
    }
    foot(&mut out);
    out
}

pub fn jobs_page(csrf: &str, jobs: &[Job]) -> String {
    let mut out = String::with_capacity(8192);
    head(&mut out, "Jobs - SketchDL", false);
    out.push_str("<h1>Downloads.</h1>");
    if jobs.is_empty() {
        out.push_str(
            "<p class=\"muted\">No downloads yet. <a href=\"/\">Inspect a video</a> to begin.</p>",
        );
    } else {
        job_list(&mut out, jobs, csrf);
    }
    foot(&mut out);
    out
}

pub fn error_page(status: u16, title: &str, detail: &str) -> String {
    let mut out = String::with_capacity(2048);
    head(&mut out, "SketchDL - error", false);
    out.push_str("<div class=\"notice error\"><h3>");
    out.push_str(&status.to_string());
    out.push_str(" &middot; ");
    out.push_str(&esc(title));
    out.push_str("</h3><p>");
    out.push_str(&esc(detail));
    out.push_str("</p></div><p><a class=\"paper-button\" href=\"/\">Home</a></p>");
    foot(&mut out);
    out
}

pub fn sse_progress(job: &Job) -> String {
    let stage = job.stage.as_deref().unwrap_or_else(|| {
        if job.state == "QUEUED" {
            "queued"
        } else if job.state == "VERIFYING" {
            "verifying"
        } else {
            "downloading"
        }
    });
    sse_values(
        &job.id,
        &job.state,
        stage,
        job.downloaded_bytes,
        job.total_bytes,
        job.speed_bps,
        job.eta_seconds,
    )
}

pub fn sse_values(
    id: &str,
    state: &str,
    stage: &str,
    downloaded: i64,
    total: Option<i64>,
    speed: Option<i64>,
    eta: Option<i64>,
) -> String {
    let pct = match total {
        Some(t) if t > 0 => ((downloaded.saturating_mul(100)) / t).min(100),
        _ => -1,
    };
    format!(
        "{{\"id\":\"{}\",\"state\":\"{}\",\"stage\":\"{}\",\"downloaded\":{},\"total\":{},\"speed\":{},\"eta\":{},\"pct\":{},\"bytes\":\"{}\",\"total_text\":\"{}\",\"speed_text\":\"{}\",\"eta_text\":\"{}\"}}",
        id,
        state,
        stage,
        downloaded,
        total
            .map(|v| v.to_string())
            .unwrap_or_else(|| "null".into()),
        speed
            .map(|v| v.to_string())
            .unwrap_or_else(|| "null".into()),
        eta.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
        pct,
        fmt_bytes(downloaded),
        total.map(fmt_bytes).unwrap_or_else(|| "unknown".into()),
        speed.map(fmt_speed).unwrap_or_default(),
        eta.map(fmt_eta).unwrap_or_default(),
    )
}

#[cfg(test)]
mod tests {
    use super::fmt_bytes;

    #[test]
    fn byte_units_do_not_inflate() {
        assert_eq!(fmt_bytes(0), "0 B");
        assert_eq!(fmt_bytes(1023), "1023 B");
        assert_eq!(fmt_bytes(1024), "1.0 KiB");
        assert_eq!(fmt_bytes(20_050_347), "19.1 MiB");
        assert_eq!(fmt_bytes(59_327_506), "56.6 MiB");
        assert_eq!(fmt_bytes(2 * 1024 * 1024 * 1024), "2.0 GiB");
    }
}
