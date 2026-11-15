// yt-dlp adapter: metadata inspection, format selection, progress parsing,
// error classification. This module builds fixed argv vectors and parses
// structured output. No shell strings, no user input in argv: the URL is
// rebuilt from a validated video id by the caller.
namespace ytdlp;

import std;
import json;
import util;

const MAX_JSON_BYTES = 4 * 1024 * 1024;
const MAX_ERROR_CHARS = 240;

struct Format {
    id: const u8[:],
    ext: const u8[:],
    height: i64,
    vcodec: const u8[:],
    acodec: const u8[:],
    size_est: i64,
    has_size: bool,
    combined: bool,
    has_video: bool,
    has_audio: bool,
    is_mp4_compat: bool,
}

struct Inspection {
    id: const u8[:],
    title: const u8[:],
    duration: i64,
    has_duration: bool,
    formats: Format[>..],
}

fn empty_format() -> Format {
    return Format { id: "", ext: "", height: 0, vcodec: "", acodec: "", size_est: 0, has_size: false,
        combined: false, has_video: false, has_audio: false, is_mp4_compat: false };
}

fn cmp_bytes(a: u8[:], b: u8[:]) -> i64 {
    let n = min(a.len, b.len);
    for i in n { if a[i] != b[i] { return a[i] as i64 - b[i] as i64; } }
    return a.len - b.len;
}

fn starts_with_v(s: u8[:], prefix: u8[:]) -> bool {
    if s.len < prefix.len { return false; }
    return s[..prefix.len] == prefix;
}

// The explicit MP4-compatible profile: MP4 container, H.264 video (avc
// family or mp4v), AAC audio (mp4a family). VP9/AV1 in an MP4 container
// are deliberately NOT compatible: the container alone proves nothing.
fn mp4_compat(f: Format) -> bool {
    if f.ext != "mp4" && f.ext != "m4a" { return false; }
    if f.vcodec.len == 0 && f.acodec.len == 0 { return false; } // dub tracks
    let v_ok = f.vcodec == "none" || starts_with_v(f.vcodec, "avc") || starts_with_v(f.vcodec, "mp4v");
    let a_ok = f.acodec == "none" || starts_with_v(f.acodec, "mp4a");
    if !v_ok || !a_ok { return false; }
    if f.vcodec != "none" && f.acodec == "none" && f.ext != "mp4" { return false; }
    return true;
}

fn fmt_field(f: Format, key: u8[:]) -> u8[:], bool {
    return "", false;
}

// Parses yt-dlp -J output. expected_id is the id we asked for; anything else
// is rejected (protects against confusion). Returns false on parse failure.
fn parse_inspection(doc_text: u8[:], expected_id: u8[:], scratch: u8[>..]&) -> Inspection, bool {
    var insp = Inspection { id: "", title: "", duration: 0, has_duration: false, formats: [] };
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(doc_text, doc, decoded);
    if err.len > 0 { return insp, false; }
    guard root else { return insp, false; }
    let id_s, ok_id = json::as_string(json::member(root, "id"));
    if !ok_id || id_s != expected_id { return insp, false; }
    var s0 = scratch.len;
    scratch.append(id_s);
    insp.id = scratch[s0..];
    let title_s, ok_t = json::as_string(json::member(root, "title"));
    if ok_t {
        var s1 = scratch.len;
        scratch.append(title_s);
        insp.title = scratch[s1..];
    }
    let dur, ok_d = json::as_i64(json::member(root, "duration"));
    if ok_d && dur >= 0 { insp.duration = dur; insp.has_duration = true; }
    let formats_node = json::member(root, "formats");
    guard formats_node else { return insp, true; }
    var fc = formats_node.first;
    while fc {
        var frow = empty_format();
        let fid, ok1 = json::as_string(json::member(fc, "format_id"));
        let ext, ok2 = json::as_string(json::member(fc, "ext"));
        let vcodec, ok3 = json::as_string(json::member(fc, "vcodec"));
        let acodec, ok4 = json::as_string(json::member(fc, "acodec"));
        let h, _okh = json::as_i64(json::member(fc, "height"));
        if ok1 && ok2 && ok3 && ok4 {
            var f0 = scratch.len;
            scratch.append(fid);
            frow.id = scratch[f0..];
            var f1 = scratch.len;
            scratch.append(ext);
            frow.ext = scratch[f1..];
            frow.height = h;
            var f2 = scratch.len;
            scratch.append(vcodec);
            frow.vcodec = scratch[f2..];
            var f3 = scratch.len;
            scratch.append(acodec);
            frow.acodec = scratch[f3..];
            let fs, okf = json::as_i64(json::member(fc, "filesize"));
            let fsa, okfa = json::as_i64(json::member(fc, "filesize_approx"));
            if okf && fs >= 0 { frow.size_est = fs; frow.has_size = true; }
            else if okfa && fsa >= 0 { frow.size_est = fsa; frow.has_size = true; }
            frow.has_video = vcodec != "none";
            frow.has_audio = acodec != "none";
            frow.combined = frow.has_video && frow.has_audio;
            frow.is_mp4_compat = mp4_compat(frow);
            insp.formats.push(frow);
        }
        fc .= fc.next;
    }
    return insp, true;
}

// Serializes the allowlist fields we keep, as compact JSON for storage.
fn formats_to_json(formats: Format[>..]&) -> u8[>..] {
    var out: u8[>..] = [];
    out.push('[');
    var first = true;
    for f in formats {
        if !first { out.push(','); }
        first = false;
        out.push('{');
        json::format_key(out, "id");
        json::format_string(out, f.id);
        out.push(',');
        json::format_key(out, "ext");
        json::format_string(out, f.ext);
        out.push(',');
        json::format_key(out, "h");
        json::format_int(out, f.height);
        out.push(',');
        json::format_key(out, "v");
        json::format_string(out, f.vcodec);
        out.push(',');
        json::format_key(out, "a");
        json::format_string(out, f.acodec);
        out.push(',');
        json::format_key(out, "size");
        if f.has_size { json::format_int(out, f.size_est); } else { out.append("null"); }
        out.push(',');
        json::format_key(out, "compat");
        json::format_bool(out, f.is_mp4_compat);
        out.push('}');
    }
    out.push(']');
    return out;
}

fn parse_stored_formats(text: u8[:], scratch: u8[>..]&) -> Format[>..] {
    var out: Format[>..] = [];
    var doc: json::Node[>..] = [];
    var decoded: u8[>..] = [];
    let root, err = json::parse(text, doc, decoded);
    if err.len > 0 { return out; }
    guard root else { return out; }
    var rc2 = root.first;
    while rc2 {
        var frow = empty_format();
        let fid, ok1 = json::as_string(json::member(rc2, "id"));
        let ext, ok2 = json::as_string(json::member(rc2, "ext"));
        let h, ok3 = json::as_i64(json::member(rc2, "h"));
        let vcodec, ok4 = json::as_string(json::member(rc2, "v"));
        let acodec, ok5 = json::as_string(json::member(rc2, "a"));
        if ok1 && ok2 && ok3 && ok4 && ok5 {
            var g0 = scratch.len;
            scratch.append(fid);
            frow.id = scratch[g0..];
            var g1 = scratch.len;
            scratch.append(ext);
            frow.ext = scratch[g1..];
            frow.height = h;
            var g2 = scratch.len;
            scratch.append(vcodec);
            frow.vcodec = scratch[g2..];
            var g3 = scratch.len;
            scratch.append(acodec);
            frow.acodec = scratch[g3..];
            let size_node = json::member(rc2, "size");
            let sz, oksz = json::as_i64(size_node);
            if oksz && sz >= 0 { frow.size_est = sz; frow.has_size = true; }
            let compat, okc = json::as_bool(json::member(rc2, "compat"));
            frow.is_mp4_compat = okc && compat;
            frow.has_video = vcodec != "none";
            frow.has_audio = acodec != "none";
            frow.combined = frow.has_video && frow.has_audio;
            out.push(frow);
        }
        rc2 .= rc2.next;
    }
    return out;
}

// Selects the best MP4-compatible video at or below ceiling. On success
// returns the -f spec text (an id, or "vid+aid") and the size estimate
// (or -1). Pure server-side decision from the stored allowlist.
fn select_format(formats: Format[>..]&, ceiling: i64, spec: u8[>..]&) -> i64 {
    var bv_i = -1;
    for i in formats.len {
        let f = formats[i];
        if f.is_mp4_compat && f.has_video && f.height > 0 && f.height <= ceiling {
            if bv_i < 0 || better_video(f, formats[bv_i]) { bv_i = i; }
        }
    }
    if bv_i < 0 { return -1; }
    let bv = formats[bv_i];
    if bv.combined {
        spec.append(bv.id);
        return if bv.has_size { bv.size_est } else { -1 };
    }
    var ba_i = -1;
    for i in formats.len {
        let f = formats[i];
        if f.is_mp4_compat && f.has_audio && !f.has_video && f.ext == "m4a" {
            if bv.has_size {
                // Pick the best audio that is no larger than the video
                // itself. Without this a 144p video paired with the 388k
                // m4a track downloaded 29 MB of audio for 4 MB of video.
                if ba_i < 0 || better_audio_for_video(f, formats[ba_i], bv.size_est) { ba_i = i; }
            } else if ba_i < 0 || better_audio(f, formats[ba_i]) {
                ba_i = i;
            }
        }
    }
    if ba_i < 0 { return -1; }
    let ba = formats[ba_i];
    spec.append(bv.id);
    spec.append("+");
    spec.append(ba.id);
    if bv.has_size && ba.has_size { return bv.size_est + ba.size_est; }
    return -1;
}

fn better_video(a: Format, b: const Format?) -> bool {
    guard b else { return true; }
    if a.height != b.height { return a.height > b.height; }
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb { return sa > sb; }
    return cmp_bytes(a.id, b.id) < 0;
}

fn better_audio(a: Format, b: const Format?) -> bool {
    guard b else { return true; }
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb { return sa > sb; }
    return cmp_bytes(a.id, b.id) < 0;
}

// Audio selection for a separate video+audio pair. A track no larger than
// the video is preferred (largest such track). If every track is larger,
// the smallest is used. This keeps audio quality proportional to the
// picture and avoids multi-megabyte audio for a tiny video.
fn better_audio_for_video(a: Format, b: const Format?, video_size: i64) -> bool {
    guard b else { return true; }
    let a_fits = a.has_size && a.size_est <= video_size;
    let b_fits = b.has_size && b.size_est <= video_size;
    if a_fits != b_fits { return a_fits; }
    let sa = if a.has_size { a.size_est } else { 0 };
    let sb = if b.has_size { b.size_est } else { 0 };
    if sa != sb {
        if a_fits { return sa > sb; }
        return sa < sb;
    }
    return cmp_bytes(a.id, b.id) < 0;
}

fn valid_format_id(id: u8[:]) -> bool {
    if id.len == 0 || id.len > 24 { return false; }
    for c in id {
        if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') { return false; }
    }
    return true;
}

// Progress lines. yt-dlp's --progress-template value is "<type>:<template>"
// and the "<type>:" part is the template's dictionary key, consumed by the
// option parser and NEVER printed. So a literal sentinel has to sit inside
// the template body. The wired line is:
//
//   skdl-progress|<done>|<total>|<estimate>|<speed>|<eta>|<format_id>|<vcodec>|<acodec>
//
// with "NA" for values yt-dlp does not know. Totals are requested as two
// separate fields so an exact total can be preferred without losing the
// estimate (HLS), and the component identity lets the aggregate below keep
// video and audio progress from resetting the job to zero.
const PROGRESS_MARKER = "skdl-progress|";
const PROGRESS_FIELDS = 8;
const MAX_COMPONENTS = 4;
const MAX_COMPONENT_ID = 40;

struct Progress {
    downloaded: i64,
    total: i64, has_total: bool,       // exact total_bytes
    estimate: i64, has_estimate: bool, // total_bytes_estimate
    speed: i64, has_speed: bool,
    eta: i64, has_eta: bool,
    format_id: u8[MAX_COMPONENT_ID], id_len: i64,
    has_video: bool, has_audio: bool,
}

fn empty_progress() -> Progress {
    return Progress { downloaded: 0, total: 0, has_total: false, estimate: 0, has_estimate: false,
        speed: 0, has_speed: false, eta: 0, has_eta: false,
        format_id: [0; MAX_COMPONENT_ID], id_len: 0, has_video: false, has_audio: false };
}

// The one place the progress argv is built. Exposed so the integration
// suite can render it exactly as yt-dlp would: a mock that hard-codes its
// own line format cannot catch a template/parser mismatch.
fn progress_template_arg(out: u8[>..]&) {
    out.append("download:");
    out.append(PROGRESS_MARKER);
    out.append("%(progress.downloaded_bytes)s|");
    out.append("%(progress.total_bytes)s|");
    out.append("%(progress.total_bytes_estimate)s|");
    out.append("%(progress.speed)s|");
    out.append("%(progress.eta)s|");
    out.append("%(info.format_id)s|");
    out.append("%(info.vcodec)s|");
    out.append("%(info.acodec)s");
}

// Strict unsigned numeric parse. Accepts digits plus one optional
// fractional part (yt-dlp prints speed as a float); truncates the fraction.
// Rejects empty/NA/None/signs/suffix garbage and avoids overflow. This is
// deliberately stricter than parse_int: "123 MB" must not become 123 bytes.
fn parse_number(tok: u8[:]) -> i64, bool {
    if tok.len == 0 { return 0, false; }
    if tok == "NA" || tok == "N/A" || tok == "None" || tok == "none" || tok == "unknown"
        || tok == "nan" || tok == "NaN" { return 0, false; }
    var v: i64 = 0;
    var i = 0;
    var digits = 0;
    while i < tok.len {
        let c = tok[i];
        if c < '0' || c > '9' { break; }
        let d = (c - '0') as i64;
        if v > (9223372036854775807 - d) / 10 { return 0, false; }
        v = v * 10 + d;
        digits += 1;
        i += 1;
    }
    if digits == 0 { return 0, false; }
    if i < tok.len && tok[i] == '.' {
        i += 1;
        var frac = 0;
        while i < tok.len && tok[i] >= '0' && tok[i] <= '9' { i += 1; frac += 1; }
        if frac == 0 { return 0, false; }
    }
    if i != tok.len { return 0, false; }
    return v, true;
}

fn copy_component_id(p: Progress&, id: u8[:]) {
    p.id_len = min(id.len, MAX_COMPONENT_ID);
    for i in p.id_len { p.format_id[i] = id[i]; }
}

fn parse_progress(line: u8[:], out: Progress&) -> bool {
    let trimmed = util::trim_line(line);
    let mlen = PROGRESS_MARKER.len;
    if !starts_with_v(trimmed, PROGRESS_MARKER) { return false; }
    let body = trimmed[mlen..];
    let parts = split(body, '|');
    if parts.len != PROGRESS_FIELDS { return false; }
    let done, ok0 = parse_number(util::trim_line(parts[0]));
    if !ok0 { return false; }
    out.downloaded = done;
    let total, ok1 = parse_number(util::trim_line(parts[1]));
    out.total = total; out.has_total = ok1;
    let est, ok2 = parse_number(util::trim_line(parts[2]));
    out.estimate = est; out.has_estimate = ok2;
    let speed, ok3 = parse_number(util::trim_line(parts[3]));
    out.speed = speed; out.has_speed = ok3;
    let eta, ok4 = parse_number(util::trim_line(parts[4]));
    out.eta = eta; out.has_eta = ok4;
    let fid = util::trim_line(parts[5]);
    copy_component_id(out, fid);
    let vcodec = util::trim_line(parts[6]);
    let acodec = util::trim_line(parts[7]);
    out.has_video = vcodec.len > 0 && vcodec != "NA" && vcodec != "none";
    out.has_audio = acodec.len > 0 && acodec != "NA" && acodec != "none";
    return true;
}

// --- progress aggregation ---------------------------------------------------

struct Component {
    id: u8[MAX_COMPONENT_ID], id_len: i64,
    downloaded: i64,
    total: i64, has_total: bool,
    has_video: bool, has_audio: bool,
    seen: bool,
}

fn empty_component() -> Component {
    return Component { id: [0; MAX_COMPONENT_ID], id_len: 0, downloaded: 0, total: 0, has_total: false,
        has_video: false, has_audio: false, seen: false };
}

// Keeps progress monotonic across yt-dlp's separate video and audio
// downloads. Each component contributes its own high-water mark; the job's
// downloaded bytes are the sum, so audio starting after video finishes never
// makes the UI jump back to "0 B". The total is only reported when every
// expected component is known and has a size: a partial total would claim
// 100% while half the job is still missing.
struct ProgressTracker {
    comps: Component[MAX_COMPONENTS],
    n: i64,
    expected: i64,
    any: bool,
    speed: i64, has_speed: bool,
    eta: i64, has_eta: bool,
    current: i64,
}

fn tracker_init(expected: i64) -> ProgressTracker {
    var t = ProgressTracker { comps: [empty_component(); MAX_COMPONENTS], n: 0,
        expected: if expected < 1 { 1 } else { expected }, any: false,
        speed: 0, has_speed: false, eta: 0, has_eta: false, current: 0 };
    return t;
}

fn component_index(t: ProgressTracker&, p: Progress) -> i64 {
    // Format id is the stable discriminator when present. If two components
    // ever share an id (or yt-dlp omits it), video/audio flags separate them.
    for i in t.n {
        let c = t.comps[i];
        if c.id_len != p.id_len { continue; }
        var same = true;
        for k in c.id_len { if c.id[k] != p.format_id[k] { same = false; } }
        if same { return i; }
    }
    if t.n < MAX_COMPONENTS {
        var c = empty_component();
        c.id_len = p.id_len;
        for k in c.id_len { c.id[k] = p.format_id[k]; }
        c.has_video = p.has_video;
        c.has_audio = p.has_audio;
        c.seen = true;
        t.comps[t.n] = c;
        t.n += 1;
        return t.n - 1;
    }
    return 0;
}

fn tracker_feed(t: ProgressTracker&, p: Progress) {
    if !p.has_video && !p.has_audio && p.id_len == 0 && t.n > 0 {
        // Some extractors omit all identity fields. Keep updating the first
        // component rather than inventing a new one per line.
        t.current = 0;
    } else {
        t.current = component_index(t, p);
    }
    var c = t.comps[t.current];
    if p.downloaded > c.downloaded { c.downloaded = p.downloaded; }
    if p.has_video { c.has_video = true; }
    if p.has_audio { c.has_audio = true; }
    if p.has_total {
        c.total = p.total; c.has_total = true;
    } else if p.has_estimate {
        c.total = p.estimate; c.has_total = true;
    }
    t.comps[t.current] = c;
    if p.has_speed { t.speed = p.speed; t.has_speed = true; }
    if p.has_eta { t.eta = p.eta; t.has_eta = true; }
    t.any = true;
}

fn tracker_downloaded(t: ProgressTracker) -> i64 {
    var sum = 0;
    for i in t.n { sum += t.comps[i].downloaded; }
    return sum;
}

fn tracker_total(t: ProgressTracker) -> i64, bool {
    if t.n < t.expected { return 0, false; }
    var sum = 0;
    for i in t.n {
        if !t.comps[i].has_total { return 0, false; }
        sum += t.comps[i].total;
    }
    if t.n == 0 { return 0, false; }
    return sum, true;
}

// "merging" once all expected bytes are in; otherwise "downloading" with a
// -video/-audio suffix for the current component. The stage label is shown
// next to the bar so a component switch is honest, not a reset.
fn tracker_stage(t: ProgressTracker, out: u8[>..]&) {
    let total, has_total = tracker_total(t);
    if has_total && tracker_downloaded(t) >= total {
        out.append("merging");
        return;
    }
    out.append("downloading");
    if t.current < 0 || t.current >= t.n { return; }
    let c = t.comps[t.current];
    if c.has_video && !c.has_audio { out.append("-video"); }
    else if c.has_audio && !c.has_video { out.append("-audio"); }
}

// Maps yt-dlp stderr to a stable error code the UI can explain, plus a
// short sanitized detail (no newlines, capped). Empty code -> success.
fn classify_error(stderr_tail: u8[:], code: u8[>..]&, detail: u8[>..]&) {
    var msg: u8[>..] = [];
    for c in stderr_tail {
        if c == '\n' { msg.push(' '); continue; }
        msg.push(c);
    }
    if find(msg, "Sign in to confirm") >= 0 { code.append("BOT_CHECK"); }
    else if find(msg, "Private video") >= 0 { code.append("PRIVATE"); }
    else if find(msg, "Requested format") >= 0 { code.append("FORMAT_UNAVAILABLE"); }
    else if find(msg, "Video unavailable") >= 0 || find(msg, "is no longer available") >= 0 { code.append("UNAVAILABLE"); }
    else if find(msg, "Sign in") >= 0 { code.append("AGE_RESTRICTED"); }
    else if find(msg, "HTTP Error 403") >= 0 || find(msg, "HTTP Error 429") >= 0 { code.append("NETWORK"); }
    else if find(msg, "no video") >= 0 || find(msg, "No formats") >= 0 { code.append("NO_FORMATS"); }
    else if msg.len > 0 { code.append("DOWNLOAD_FAILED"); }
    let short = if msg.len > MAX_ERROR_CHARS { msg[..MAX_ERROR_CHARS] } else { msg };
    detail.append(short);
}
