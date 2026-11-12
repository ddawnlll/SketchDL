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
    var ba_i = -1;
    for i in formats.len {
        let f = formats[i];
        if f.is_mp4_compat && f.has_video && f.height > 0 && f.height <= ceiling {
            if bv_i < 0 || better_video(f, formats[bv_i]) { bv_i = i; }
        }
        if f.is_mp4_compat && f.has_audio && !f.has_video && f.ext == "m4a" {
            if ba_i < 0 || better_audio(f, formats[ba_i]) { ba_i = i; }
        }
    }
    if bv_i < 0 { return -1; }
    let bv = formats[bv_i];
    if bv.combined {
        spec.append(bv.id);
        return if bv.has_size { bv.size_est } else { -1 };
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

fn valid_format_id(id: u8[:]) -> bool {
    if id.len == 0 || id.len > 24 { return false; }
    for c in id {
        if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') { return false; }
    }
    return true;
}

// progress template line: download:<done>|<total>|<speed>|<eta>, with "NA"
// possible for total/speed/eta. Speed may be a float ("1500337.9...").
struct Progress { downloaded: i64, total: i64, has_total: bool, speed: i64, has_speed: bool, eta: i64, has_eta: bool }

fn parse_number(tok: u8[:]) -> i64, bool {
    if tok.len == 0 || tok == "NA" { return 0, false; }
    var v = 0;
    var i = 0;
    var any = false;
    while i < tok.len {
        let c = tok[i];
        if c >= '0' && c <= '9' { v = v * 10 + (c - '0'); any = true; i += 1; continue; }
        if c == '.' { break; }
        break;
    }
    if !any { return 0, false; }
    return v, true;
}

fn parse_progress(line: u8[:], out: Progress&) -> bool {
    if !starts_with_v(line, "download:") { return false; }
    let body = line[9..];
    let parts = split(body, '|');
    if parts.len != 4 { return false; }
    let done, ok0 = parse_number(parts[0]);
    if !ok0 { return false; }
    out.downloaded = done;
    let total, ok1 = parse_number(parts[1]);
    out.total = total; out.has_total = ok1;
    let speed, ok2 = parse_number(parts[2]);
    out.speed = speed; out.has_speed = ok2;
    let eta, ok3 = parse_number(parts[3]);
    out.eta = eta; out.has_eta = ok3;
    return true;
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
