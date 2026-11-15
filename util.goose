// Shared helpers: form parsing, HTML escaping, time formatting,
// URL parsing. All inputs from the network are treated as hostile here.
namespace util;

import std;

const MAX_FORM_BYTES = 8 * 1024;
const MAX_FORM_FIELDS = 16;

struct Field { name: const u8[:], value: const u8[:] }

struct Form { fields: Field[64], n: i64 }

// Percent-decode one form component (application/x-www-form-urlencoded).
// Returns false on malformed percent escapes.
fn form_decode(out: u8[>..]&, text: u8[:]) -> bool {
    var i = 0;
    while i < text.len {
        let c = text[i];
        if c == '+' { out.push(' '); i += 1; continue; }
        if c == '%' {
            if i + 2 >= text.len { return false; }
            let hi = hex_val(text[i + 1]);
            let lo = hex_val(text[i + 2]);
            if hi < 0 || lo < 0 { return false; }
            out.push(((hi << 4) | lo) as u8);
            i += 3;
            continue;
        }
        out.push(c);
        i += 1;
    }
    return true;
}

fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// Parse a form body into fixed slots (no heap, bounded). The decoded bytes
// live in `scratch`; the fields borrow from it. False on malformed input.
fn parse_form(body: u8[:], scratch: u8[>..]&, form: Form&) -> bool {
    if body.len > MAX_FORM_BYTES { return false; }
    form.n = 0;
    var pos = 0;
    loop {
        if pos > body.len { break; }
        var amp = pos;
        while amp < body.len && body[amp] != '&' { amp += 1; }
        let pair = body[pos..amp];
        if pair.len > 0 {
            if form.n >= MAX_FORM_FIELDS { return false; }
            var eq = 0;
            while eq < pair.len && pair[eq] != '=' { eq += 1; }
            let name_raw = if eq < pair.len { pair[..eq] } else { pair };
            let value_raw = if eq < pair.len { pair[eq + 1..] } else { "" };
            var dname: u8[>..] = [];
            var dvalue: u8[>..] = [];
            if !form_decode(dname, name_raw) || !form_decode(dvalue, value_raw) { return false; }
            let ns = scratch.len;
            scratch.append(dname);
            let vs = scratch.len;
            scratch.append(dvalue);
            form.fields[form.n].name = scratch[ns..vs];
            form.fields[form.n].value = scratch[vs..];
            form.n += 1;
        }
        if amp >= body.len { break; }
        pos = amp + 1;
    }
    return true;
}

fn form_get(form: Form, name: u8[:]) -> u8[:], bool {
    for i in form.n {
        if form.fields[i].name == name { return form.fields[i].value, true; }
    }
    return "", false;
}

// UTF-8 validation with the strict rules of Unicode Table 3-7 (overlong
// forms, surrogates and values past U+10FFFF are rejected).
fn utf8_valid(s: u8[:]) -> bool { return utf8_count(s) >= 0; }

fn utf8_count(s: u8[:]) -> i64 {
    var i = 0;
    var count = 0;
    while i < s.len {
        let b = s[i] as i64;
        if b < 0x80 { i += 1; count += 1; continue; }
        var n = 0;
        var lo = 0x80;
        var hi = 0xBF;
        if b >= 0xC2 && b <= 0xDF { n = 2; }
        else if b >= 0xE0 && b <= 0xEF {
            n = 3;
            if b == 0xE0 { lo = 0xA0; } else if b == 0xED { hi = 0x9F; }
        } else if b >= 0xF0 && b <= 0xF4 {
            n = 4;
            if b == 0xF0 { lo = 0x90; } else if b == 0xF4 { hi = 0x8F; }
        }
        if n == 0 { return -1; }
        var k = 1;
        while k < n && i + k < s.len {
            let c = s[i + k] as i64;
            if c < lo || c > hi { break; }
            lo = 0x80; hi = 0xBF;
            k += 1;
        }
        if k != n { return -1; }
        i += n;
        count += 1;
    }
    return count;
}

// HTML-escape text for element and attribute contexts.
fn html_escape(out: u8[>..]&, s: u8[:]) {
    for c in s {
        match c {
            '&' => out.append("&amp;"),
            '<' => out.append("&lt;"),
            '>' => out.append("&gt;"),
            '"' => out.append("&quot;"),
            '\'' => out.append("&#x27;"),
            _ => out.push(c),
        }
    }
}

// human readable bytes: "1.2 MiB" / "812 KiB" / "340 B".
fn fmt_bytes(out: u8[>..]&, bytes: i64) {
    if bytes < 0 { out.append("unknown size"); return; }
    if bytes < 1024 { format(out, bytes, " B"); return; }
    var unit = 1024;
    var name = "KiB";
    if bytes >= 1024 * 1024 * 1024 { unit = 1024 * 1024 * 1024; name = "GiB"; }
    else if bytes >= 1024 * 1024 { unit = 1024 * 1024; name = "MiB"; }
    let whole = bytes / unit;
    let frac = (bytes % unit) * 10 / unit;
    format(out, whole, ".", frac, " ", name);
}

// "3:25" for durations, "1:02:30" past an hour.
fn fmt_duration(out: u8[>..]&, seconds: i64) {
    if seconds < 0 { out.append("unknown length"); return; }
    let h = seconds / 3600;
    let m = (seconds % 3600) / 60;
    let s = seconds % 60;
    if h > 0 { format(out, h, ":", m / 10, m % 10, ":", s / 10, s % 10); return; }
    format(out, m, ":", s / 10, s % 10);
}

// "about 12 minutes left" / "under a minute left" from an eta in seconds.
fn fmt_eta(out: u8[>..]&, eta: i64) {
    if eta < 0 { out.append("time remaining unknown"); return; }
    if eta < 60 { out.append("under a minute left"); return; }
    let mins = eta / 60;
    if mins < 60 { format(out, "about ", mins, " min left"); return; }
    format(out, "about ", mins / 60, " h ", mins % 60, " min left");
}

fn fmt_speed(out: u8[>..]&, bps: i64) {
    if bps < 0 { out.append("speed unknown"); return; }
    if bps == 0 { out.append("stalled"); return; }
    fmt_bytes(out, bps);
    out.append("/s");
}

// --- bounded byte tails -------------------------------------------------

// Returns the newest at most `cap` bytes of `buf`. Goose's pop_n drops
// elements from the END, so trimming a bounded tail with pop_n would keep
// the oldest bytes and throw away the newest progress/error lines. Every
// bounded tail in the subprocess loops goes through this helper.
fn newest_tail(buf: u8[:], cap: i64) -> u8[>..] {
    var out: u8[>..] = [];
    if cap <= 0 { return out; }
    if buf.len <= cap { out.append(buf); return out; }
    out.append(buf[buf.len - cap..]);
    return out;
}

// Trim ASCII spaces, tabs and trailing CR (yt-dlp may emit CRLF on some
// platforms; a stray '\r' must not turn a valid number into garbage).
fn trim_line(s: u8[:]) -> u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r') { a += 1; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r') { b -= 1; }
    return s[a..b];
}

// Date helpers (UTC, civil from days).
fn is_leap(y: i64) -> bool { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 => 31, 2 => if is_leap(y) { 29 } else { 28 }, 3 => 31, 4 => 30, 5 => 31, 6 => 30,
        7 => 31, 8 => 31, 9 => 30, 10 => 31, 11 => 30, 12 => 31,
        _ => 30,
    }
}

// "2026-11-12 16:57 UTC" from epoch seconds.
fn fmt_time(out: u8[>..]&, epoch: i64) {
    var days = epoch / 86400;
    var secs = epoch % 86400;
    if secs < 0 { secs += 86400; days -= 1; }
    var y = 1970;
    loop {
        let dy: i64 = if is_leap(y) { 366 } else { 365 };
        if days >= dy { days -= dy; y += 1; continue; }
        break;
    }
    var m = 1;
    loop {
        let dm = days_in_month(y, m);
        if days >= dm { days -= dm; m += 1; continue; }
        break;
    }
    let day = days + 1;
    let hh = secs / 3600;
    let mm = (secs % 3600) / 60;
    format(out, y, "-", m / 10, m % 10, "-", day / 10, day % 10, " ", hh / 10, hh % 10, ":", mm / 10, mm % 10, " UTC");
}
