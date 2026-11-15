// Server-rendered HTML templates (zero JavaScript). Every dynamic string
// is HTML-escaped here; nothing from the network or metadata is ever
// inserted raw.
namespace views;

import std;
import util;
import db;
import ytdlp;

const CSP = "default-src 'none'; style-src 'self'; img-src 'none'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

const LOGO_SVG = "<svg class=\"word-sketch\" viewBox=\"0 0 48 48\" width=\"32\" height=\"32\" aria-hidden=\"true\"><path d=\"M6 30 L26 10 L30 14 L12 34 Z\"/><path d=\"M26 10 L34 6 L40 12 L33 20\"/><path d=\"M8 40 Q24 36 42 39\"/></svg>";

const PENCIL_SVG = "<svg class=\"hero\" viewBox=\"0 0 400 170\" role=\"img\" aria-label=\"A pencil sketching a download arrow into a tray\"><path class=\"drawn-path\" d=\"M30 120 Q90 60 190 88 T360 70\"/><path class=\"drawn-path delay-1\" d=\"M150 44 L150 108 M132 92 L150 110 L168 92\"/><path class=\"drawn-accent\" d=\"M52 128 Q180 140 348 126\"/><path class=\"drawn-path delay-2\" d=\"M60 146 L340 144\"/><path class=\"drawn-moss\" d=\"M330 30 l8 -12 M338 38 l12 -6\"/></svg>";

const LOCK_SVG = "<svg viewBox=\"0 0 48 48\" width=\"40\" height=\"40\" aria-hidden=\"true\"><path d=\"M14 22 v-6 a10 10 0 0 1 20 0 v6\"/><rect x=\"10\" y=\"22\" width=\"28\" height=\"20\" rx=\"4\"/><circle cx=\"24\" cy=\"30\" r=\"3\"/><path d=\"M24 33 v4\"/></svg>";

fn head(out: u8[>..]&, title: u8[:], refresh: bool) {
    out.append("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    out.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
    if refresh { out.append("<meta http-equiv=\"refresh\" content=\"3\">"); }
    out.append("<title>");
    util::html_escape(out, title);
    out.append("</title>");
    out.append("<link rel=\"stylesheet\" href=\"/assets/style.css\">");
    out.append("<meta name=\"color-scheme\" content=\"light\">");
    out.append("</head><body><header class=\"site\"><a class=\"brand\" href=\"/\">");
    out.append(LOGO_SVG);
    out.append("<span>SketchDL</span></a>");
    out.append("<nav class=\"nav-links\"><a href=\"/jobs\">Jobs</a>");
    out.append("</nav></header><main>");
}

fn foot(out: u8[>..]&) {
    out.append("</main><footer class=\"site\"><p>SketchDL &middot; zero-JavaScript downloader &middot; your downloads stay on your own disk.</p></footer></body></html>");
}

fn login_page(out: u8[>..]&, error_msg: u8[:], has_error: bool) {
    head(out, "Log in - SketchDL", false);
    out.append(PENCIL_SVG);
    out.append("<h1>Welcome back.</h1><p class=\"lead\">This sketchbook is private. Log in to copy a video you own or are allowed to download.</p>");
    if has_error {
        out.append("<div class=\"notice error\"><h3>Could not log in.</h3><p>");
        util::html_escape(out, error_msg);
        out.append("</p></div>");
    }
    out.append("<form class=\"card\" method=\"post\" action=\"/login\" autocomplete=\"off\">");
    out.append("<div class=\"field\"><label for=\"pw\">Owner password "); out.append(LOCK_SVG); out.append("</label>");
    out.append("<input id=\"pw\" name=\"password\" type=\"password\" autocomplete=\"current-password\" required minlength=\"12\" maxlength=\"1024\">");
    out.append("</div><div class=\"field-hint\">Passwords are verified with Argon2id on the server. Several wrong tries pause login for a while.</div><div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Open my sketchbook</button></div></form>");
    foot(out);
}

fn home_page(out: u8[>..]&, csrf: u8[:], jobs: db::Job[>..]&, error_msg: u8[:], has_error: bool) {
    head(out, "SketchDL - home", false);
    out.append("<h1>Paste a YouTube link.</h1>");
    out.append("<p class=\"lead\">SketchDL previews one video at a time and saves it as an MP4 you can download from here. Single videos only.</p>");
    if has_error {
        out.append("<div class=\"notice error\"><h3>That link did not work.</h3><p>");
        util::html_escape(out, error_msg);
        out.append("</p></div>");
    }
    out.append("<form class=\"card\" method=\"post\" action=\"/inspect\" autocomplete=\"off\">");
    out.append("<input type=\"hidden\" name=\"csrf\" value=\"");
    out.append(csrf);
    out.append("\"><div class=\"field\"><label for=\"url\">Video URL</label>");
    out.append("<input id=\"url\" name=\"url\" type=\"url\" inputmode=\"url\" placeholder=\"https://www.youtube.com/watch?v=...\" required maxlength=\"2048\">");
    out.append("<div class=\"field-hint\">Accepted: youtube.com watch, shorts, and youtu.be links. The link is rebuilt canonically before anything runs.</div></div>");
    out.append("<div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Inspect video</button></div></form>");
    out.append("<h2>Recent downloads</h2>");
    if jobs.len == 0 {
        out.append("<p class=\"muted\">Nothing yet. Your first sketch will appear here.</p>");
    } else {
        job_list(out, jobs, csrf);
    }
    foot(out);
}

fn state_class(state: u8[:]) -> u8[:] {
    if state == "READY" { return "ready"; }
    if state == "DOWNLOADING" { return "downloading"; }
    if state == "QUEUED" { return "queued"; }
    if state == "VERIFYING" { return "verifying"; }
    if state == "FAILED" { return "failed"; }
    if state == "CANCELLED" { return "cancelled"; }
    if state == "EXPIRED" { return "expired"; }
    return "queued";
}

fn state_label(state: u8[:]) -> u8[:] {
    if state == "READY" { return "ready"; }
    if state == "DOWNLOADING" { return "downloading"; }
    if state == "QUEUED" { return "queued"; }
    if state == "VERIFYING" { return "checking"; }
    if state == "FAILED" { return "failed"; }
    if state == "CANCELLED" { return "cancelled"; }
    if state == "EXPIRED" { return "expired"; }
    return "queued";
}

fn job_row(out: u8[>..]&, job: db::Job, csrf: u8[:]) {
    out.append("<li class=\"job-row\"><a class=\"title\" href=\"/jobs/");
    out.append(job.id);
    out.append("\">");
    if job.has_title { util::html_escape(out, job.title); } else { util::html_escape(out, job.video_id); }
    out.append("</a> <span class=\"state ");
    out.append(state_class(job.state));
    out.append("\">");
    out.append(state_label(job.state));
    out.append("</span><div class=\"sub\">");
    out.append("<span class=\"muted\">");
    util::fmt_time(out, job.created_at);
    out.append("</span>");
    if job.has_output {
        out.append(" &middot; ");
        util::fmt_bytes(out, job.output_bytes);
    }
    out.append("</div><div class=\"actions\">");
    if job.state == "READY" {
        out.append("<a class=\"paper-button primary\" href=\"/downloads/");
        out.append(job.id);
        out.append("\">Download MP4</a>");
    }
    if job.state == "QUEUED" || job.state == "DOWNLOADING" || job.state == "VERIFYING" {
        out.append("<form class=\"inline\" method=\"post\" action=\"/jobs/");
        out.append(job.id);
        out.append("/cancel\"><input type=\"hidden\" name=\"csrf\" value=\"");
        out.append(csrf);
        out.append("\"><button class=\"paper-button danger\" type=\"submit\">Cancel</button></form>");
    }
    if job.state == "FAILED" || job.state == "CANCELLED" {
        out.append("<form class=\"inline\" method=\"post\" action=\"/jobs/");
        out.append(job.id);
        out.append("/retry\"><input type=\"hidden\" name=\"csrf\" value=\"");
        out.append(csrf);
        out.append("\"><button class=\"paper-button\" type=\"submit\">Retry</button></form>");
    }
    out.append("<form class=\"inline\" method=\"post\" action=\"/jobs/");
    out.append(job.id);
    out.append("/delete\"><input type=\"hidden\" name=\"csrf\" value=\"");
    out.append(csrf);
    out.append("\"><button class=\"paper-button\" type=\"submit\">Remove</button></form>");
    out.append("</div></li>");
}

fn job_list(out: u8[>..]&, jobs: db::Job[>..]&, csrf: u8[:]) {
    out.append("<ul class=\"job-list\">");
    for j in jobs { job_row(out, j, csrf); }
    out.append("</ul>");
}

fn inspect_page(out: u8[>..]&, csrf: u8[:], token: u8[:], title: u8[:], duration: i64, has_duration: bool, formats: ytdlp::Format[>..]&, video_id: u8[:]) {
    head(out, "Inspect - SketchDL", false);
    out.append("<h1>");
    util::html_escape(out, title);
    out.append("</h1>");
    out.append("<p class=\"lead\">");
    out.append("<a href=\"https://www.youtube.com/watch?v=");
    out.append(video_id);
    out.append("\">View on YouTube</a>");
    if has_duration {
        out.append(" &middot; ");
        util::fmt_duration(out, duration);
    }
    out.append("</p>");
    out.append("<p class=\"muted\">Choose a quality. Only H.264 video with AAC audio (MP4-compatible) is listed; sizes are estimates from YouTube.</p>");
    out.append("<form class=\"card\" method=\"post\" action=\"/jobs\">");
    out.append("<input type=\"hidden\" name=\"csrf\" value=\"");
    out.append(csrf);
    out.append("\"><input type=\"hidden\" name=\"inspect\" value=\"");
    out.append(token);
    out.append("\"><fieldset class=\"fs-plain\"><legend class=\"muted\">Quality</legend><ul class=\"format-list\">");
    var first = true;
    for f in formats {
        if !f.is_mp4_compat { continue; }
        if !f.has_video { continue; }
        if f.height <= 0 { continue; }
        var label: u8[>..] = [];
        format(label, f.height, "p");
        out.append("<li><label class=\"format-row\"><input type=\"radio\" name=\"preset\" value=\"");
        out.append(label);
        out.append("\"");
        if first { out.append(" checked"); first = false; }
        out.append("><span class=\"q\">");
        out.append(label);
        out.append("</span><span class=\"meta\">");
        if f.combined { out.append("single file"); } else { out.append("H.264 + AAC"); }
        out.append("</span><span class=\"size\">");
        if f.has_size { util::fmt_bytes(out, f.size_est); } else { out.append("size unknown"); }
        out.append("</span></label></li>");
    }
    out.append("</ul></fieldset>");
    out.append("<div class=\"button-row mt\"><button class=\"paper-button primary\" type=\"submit\">Start download</button><a class=\"paper-button\" href=\"/\">Back</a></div>");
    out.append("<div class=\"field-hint\">This preview expires in a few minutes. The download is server-side; nothing is sent to your browser except the finished file.</div></form>");
    foot(out);
}

fn inspect_empty(out: u8[>..]&, csrf: u8[:], message: u8[:]) {
    head(out, "Inspect - SketchDL", false);
    out.append("<h1>No compatible video found.</h1>");
    out.append("<div class=\"notice error\"><h3>FORMAT_UNAVAILABLE</h3><p>");
    util::html_escape(out, message);
    out.append("</p></div>");
    out.append("<form class=\"card\" method=\"post\" action=\"/inspect\" autocomplete=\"off\">");
    out.append("<input type=\"hidden\" name=\"csrf\" value=\"");
    out.append(csrf);
    out.append("\"><div class=\"field\"><label for=\"url\">Try another link</label><input id=\"url\" name=\"url\" type=\"url\" required maxlength=\"2048\"></div><div class=\"button-row\"><button class=\"paper-button primary\" type=\"submit\">Inspect video</button><a class=\"paper-button\" href=\"/\">Home</a></div></form>");
    foot(out);
}

fn stage_label(out: u8[>..]&, job: db::Job) {
    if job.has_stage && job.stage == "starting" { out.append("Preparing the download"); return; }
    if job.has_stage && job.stage == "merging" { out.append("Merging the file"); return; }
    if job.has_stage && job.stage == "downloading-video" { out.append("Downloading video"); return; }
    if job.has_stage && job.stage == "downloading-audio" { out.append("Downloading audio"); return; }
    out.append("Downloading");
}

fn show_rate(job: db::Job) -> bool {
    if !job.has_stage { return true; }
    return job.stage != "starting" && job.stage != "merging" && job.stage != "verifying";
}

fn job_page(out: u8[>..]&, csrf: u8[:], job: db::Job, facts: u8[:]) {
    let active = job.state == "QUEUED" || job.state == "DOWNLOADING" || job.state == "VERIFYING";
    head(out, "Job - SketchDL", active);
    out.append("<p class=\"muted\"><a href=\"/jobs\">&larr; all jobs</a></p>");
    out.append("<h1>");
    if job.has_title { util::html_escape(out, job.title); } else { util::html_escape(out, job.video_id); }
    out.append("</h1>");
    out.append("<p class=\"lead\"><span class=\"state ");
    out.append(state_class(job.state));
    out.append("\">");
    out.append(state_label(job.state));
    out.append("</span></p>");

    if job.state == "READY" {
        out.append("<svg class=\"checkmark drawn\" viewBox=\"0 0 60 60\" width=\"60\" height=\"60\" role=\"img\" aria-label=\"Download completed\"><path d=\"M12 32 L24 44 L50 18\"/></svg>");
        out.append("<div class=\"progress-meta\"><span>MP4");
        if job.has_output { out.append(" &middot; "); util::fmt_bytes(out, job.output_bytes); }
        if job.has_expires { out.append(" &middot; expires "); util::fmt_time(out, job.expires_at); }
        out.append("</span>");
        if facts.len > 0 { out.append("<span>"); util::html_escape(out, facts); out.append("</span>"); }
        out.append("</div>");
        out.append("<div class=\"button-row mt\"><a class=\"paper-button primary\" href=\"/downloads/");
        out.append(job.id);
        out.append("\">Download MP4</a><a class=\"paper-button\" href=\"/jobs\">All jobs</a></div>");
    } else if job.state == "FAILED" || job.state == "CANCELLED" || job.state == "EXPIRED" {
        out.append("<div class=\"notice error\"><h3>");
        if job.state == "EXPIRED" { out.append("This download expired."); }
        else if job.state == "CANCELLED" { out.append("Download cancelled."); }
        else { out.append("Something went wrong."); }
        out.append("</h3>");
        if job.has_error {
            out.append("<p><span class=\"code\">");
            util::html_escape(out, job.error_code);
            out.append("</span></p>");
        }
        if job.has_detail {
            out.append("<p class=\"muted small\">");
            util::html_escape(out, job.error_detail);
            out.append("</p>");
        }
        out.append("</div><div class=\"button-row\"><form class=\"inline\" method=\"post\" action=\"/jobs/");
        out.append(job.id);
        out.append("/retry\"><input type=\"hidden\" name=\"csrf\" value=\"");
        out.append(csrf);
        out.append("\"><button class=\"paper-button primary\" type=\"submit\">Try again</button></form><a class=\"paper-button\" href=\"/\">New video</a></div>");
    } else {
        // active: progress display
        out.append("<div class=\"progress-wrap\">");
        if job.state == "QUEUED" {
            out.append("<p class=\"stage-label\">Waiting its turn</p><div class=\"indeterminate\" aria-label=\"Waiting\"><span class=\"nip\"></span></div>");
            out.append("<p class=\"muted\">One download runs at a time. This page refreshes automatically.</p>");
        } else if job.state == "VERIFYING" {
            out.append("<p class=\"stage-label\">Checking the file</p><div class=\"indeterminate\" aria-label=\"Verifying\"><span class=\"nip\"></span></div>");
        } else if job.has_total && job.total_bytes > 0 && job.downloaded_bytes >= 0 {
            var pct = (job.downloaded_bytes * 100) / job.total_bytes;
            if pct > 100 { pct = 100; }
            out.append("<p class=\"stage-label\">");
            stage_label(out, job);
            out.append("</p>");
            out.append("<progress max=\"100\" value=\"");
            format(out, pct);
            out.append("\" aria-label=\"Download progress\">");
            format(out, pct);
            out.append("% complete</progress>");
            out.append("<div class=\"progress-meta\"><span>");
            util::fmt_bytes(out, job.downloaded_bytes);
            out.append(" of ");
            util::fmt_bytes(out, job.total_bytes);
            out.append("</span>");
            if job.has_speed && show_rate(job) { out.append("<span>"); util::fmt_speed(out, job.speed_bps); out.append("</span>"); }
            if job.has_eta && show_rate(job) { out.append("<span>"); util::fmt_eta(out, job.eta_seconds); out.append("</span>"); }
            out.append("</div>");
        } else {
            out.append("<p class=\"stage-label\">");
            stage_label(out, job);
            out.append("</p><div class=\"indeterminate\" aria-label=\"Downloading, total size unknown\"><span class=\"nip\"></span></div>");
            out.append("<div class=\"progress-meta\"><span>");
            util::fmt_bytes(out, job.downloaded_bytes);
            out.append(" so far</span>");
            if job.has_speed && show_rate(job) { out.append("<span>"); util::fmt_speed(out, job.speed_bps); out.append("</span>"); }
            out.append("</div>");
        }
        out.append("</div>");
        out.append("<p class=\"muted small\">This page refreshes every 3 seconds while downloading. Progress is real data from the server, not an animation.</p>");
        out.append("<form class=\"inline\" method=\"post\" action=\"/jobs/");
        out.append(job.id);
        out.append("/cancel\"><input type=\"hidden\" name=\"csrf\" value=\"");
        out.append(csrf);
        out.append("\"><button class=\"paper-button danger\" type=\"submit\">Cancel download</button></form>");
    }
    foot(out);
}

fn jobs_page(out: u8[>..]&, csrf: u8[:], jobs: db::Job[>..]&) {
    head(out, "Jobs - SketchDL", false);
    out.append("<h1>Downloads.</h1>");
    if jobs.len == 0 {
        out.append("<p class=\"muted\">No downloads yet. <a href=\"/\">Inspect a video</a> to begin.</p>");
    } else {
        job_list(out, jobs, csrf);
    }
    foot(out);
}

fn error_page(out: u8[>..]&, status: i64, title: u8[:], detail: u8[:]) {
    head(out, "SketchDL - error", false);
    out.append("<div class=\"notice error\"><h3>");
    format(out, status);
    out.append(" &middot; ");
    util::html_escape(out, title);
    out.append("</h3><p>");
    util::html_escape(out, detail);
    out.append("</p></div><p><a class=\"paper-button\" href=\"/\">Home</a></p>");
    foot(out);
}
