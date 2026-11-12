// Strict YouTube URL validation. The only thing this module ever produces
// is an 11-character video id plus a canonical watch URL rebuilt from it.
// Raw user input is never forwarded to yt-dlp, HTML, or the filesystem.
namespace input;

import std;

const MAX_URL_BYTES = 2048;

fn is_id_char(c: u8) -> bool {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

fn valid_id(id: u8[:]) -> bool {
    if id.len != 11 { return false; }
    for c in id { if !is_id_char(c) { return false; } }
    return true;
}

fn trim_ws(s: u8[:]) -> u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\n' || s[a] == '\r') { a += 1; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\n' || s[b - 1] == '\r') { b -= 1; }
    return s[a..b];
}

// Case-insensitive exact match with one of the allowlisted hosts.
fn host_ok(host: u8[:]) -> bool {
    return host_eq(host, "youtube.com") || host_eq(host, "www.youtube.com")
        || host_eq(host, "m.youtube.com") || host_eq(host, "youtu.be");
}

fn host_eq(host: u8[:], want: u8[:]) -> bool {
    if host.len != want.len { return false; }
    for i in host.len {
        let a = host[i];
        let b = want[i];
        var ca = a;
        if ca >= 'A' && ca <= 'Z' { ca += 32; }
        if ca != b { return false; }
    }
    return true;
}

// Extract the first `v` query parameter value (undecoded: ids are plain).
fn query_v(query: u8[:]) -> u8[:], bool {
    var pos = 0;
    loop {
        if pos > query.len { break; }
        var amp = pos;
        while amp < query.len && query[amp] != '&' { amp += 1; }
        let pair = query[pos..amp];
        if pair.len >= 2 && pair[0] == 'v' && pair[1] == '=' {
            return pair[2..], true;
        }
        if amp >= query.len { break; }
        pos = amp + 1;
    }
    return "", false;
}

// Validates a pasted URL. On success, `id_out` receives the 11-char id
// ("..." appended) and `canon_out` the canonical watch URL. Error codes:
// 0 ok, 1 empty, 2 too long, 3 bad scheme/host/path, 4 bad id.
fn parse_youtube_url(text: u8[:], id_out: u8[>..]&, canon_out: u8[>..]&) -> i64 {
    let url = trim_ws(text);
    if url.len == 0 { return 1; }
    if url.len > MAX_URL_BYTES { return 2; }
    for c in url {
        if c == '#' || c == '`' || c == '"' || c == '<' || c == '>' || c == ' ' || c == '\\' { return 3; }
        if c < 0x21 { return 3; }
    }
    if !starts_with(url, "https://") { return 3; }
    let rest = url[8..];
    // Authority: up to the first '/', '?' or end. Must contain no '@' or ':'.
    var auth_end = 0;
    while auth_end < rest.len && rest[auth_end] != '/' && rest[auth_end] != '?' { auth_end += 1; }
    let host = rest[..auth_end];
    if host.len == 0 || host.len > 64 { return 3; }
    for c in host {
        if c == '@' || c == ':' || c == '%' { return 3; }
    }
    if !host_ok(host) { return 3; }
    let tail = rest[auth_end..];
    // Split path and query.
    var qpos = -1;
    for i in tail.len { if tail[i] == '?' { qpos = i; break; } }
    let path = if qpos >= 0 { tail[..qpos] } else { tail };
    let query = if qpos >= 0 { tail[qpos + 1..] } else { "" };
    var id_b: u8[>..] = [];
    var has_id = false;
    if host_eq(host, "youtu.be") {
        // path must be /<id> exactly (no trailing junk).
        if path.len < 2 || path[0] != '/' { return 3; }
        let seg = path[1..];
        var e = 0;
        while e < seg.len && seg[e] != '/' { e += 1; }
        if e != seg.len { return 3; }
        id_b.append(seg);
        has_id = true;
    } else if path == "/watch" {
        let v, ok = query_v(query);
        if !ok { return 4; }
        id_b.append(v);
        has_id = true;
    } else if starts_with(path, "/shorts/") || starts_with(path, "/embed/") || starts_with(path, "/live/") {
        let seg = if starts_with(path, "/shorts/") { path[8..] } else if starts_with(path, "/embed/") { path[7..] } else { path[6..] };
        var e = 0;
        while e < seg.len && seg[e] != '/' { e += 1; }
        if e != seg.len { return 3; }
        id_b.append(seg);
        has_id = true;
    }
    if !has_id { return 3; }
    if !valid_id(id_b) { return 4; }
    id_out.append(id_b);
    canon_out.append("https://www.youtube.com/watch?v=");
    canon_out.append(id_b);
    return 0;
}
