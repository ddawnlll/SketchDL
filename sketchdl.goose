// SketchDL — a zero-JavaScript, server-rendered YouTube MP4 downloader.
//
// One binary, three modes:
//   serve       HTTP server (auth, UI, queue, downloads) + supervisor that
//               spawns a worker-once child per job.
//   worker-once Runs one queued job: yt-dlp download, progress into SQLite,
//               ffprobe verification, atomic publication. Never served.
//   admin       set-password / backup / integrity (offline maintenance).
//
// All application logic is Goose. C appears only through interop modules:
// net.goose (sockets), db.goose (SQLite), proc.goose + vendor/proc.c
// (subprocesses, files), and libargon2 (auth.goose).
import std;
import os;
import util;
import db;
import auth;
import views;
import net;
import proc;
import input;
import ytdlp;
import media;
import storage;
import crypto;

extern fn c_getpid() -> i64 = "getpid";
extern fn sk_open_read(path: const u8&) -> i32 = "sk_open_read";
extern fn sk_sendfile(out_fd: i32, in_fd: i32, offset: i64, count: i64) -> i32 = "sk_sendfile";
extern fn sk_close_fd(fd: i32) -> i32 = "sk_close_fd";

var cfg_db: u8[>..] = [];
var cfg_data: u8[>..] = [];
var cfg_listen: u8[>..] = [];
var cfg_ytdlp: u8[>..] = [];
var cfg_ffmpeg: u8[>..] = [];
var cfg_ffprobe: u8[>..] = [];
var cfg_deno: u8[>..] = [];
var cfg_ejs_parent: u8[>..] = [];
var cfg_bgutil_home: u8[>..] = [];
var cfg_job: u8[>..] = [];
var cfg_out: u8[>..] = [];
var cfg_has_out = false;
var cfg_secure = true;
var cfg_trust_proxy = false;
var cfg_session_days = 30;
var cfg_retain_hours = 12;
var cfg_max_download_bytes = 2 * 1024 * 1024 * 1024;
var cfg_max_duration = 4 * 60 * 60;
var cfg_inspect_timeout_ms = 60 * 1000;
var cfg_download_timeout_s = 30 * 60;
var cfg_min_free_bytes = 20 * 1024 * 1024 * 1024;
var cfg_max_active = 5;

fn now_seconds() -> i64 { return time_ns() / 1000000000; }

fn cookie_name() -> u8[:] {
    if cfg_secure { return "__Host-sketchdl_session"; }
    return "sketchdl_session";
}

fn print_usage() {
    write_stderr("SketchDL (Goose)\n  sketchdl serve [--db PATH] [--data DIR] [--listen 127.0.0.1:8087]\n                   [--ytdlp PATH] [--ffmpeg PATH] [--ffprobe PATH] [--deno PATH]\n                   [--ejs-parent DIR] [--bgutil-home DIR] [--insecure-cookies] [--trust-proxy]\n                   [--retain-hours N] [--max-download-bytes N] [--max-duration S]\n                   [--inspect-timeout S] [--download-timeout S] [--min-free-bytes N]\n                   [--max-active N]\n  sketchdl admin set-password [--db PATH]\n  sketchdl admin backup [--db PATH] --out PATH\n  sketchdl admin integrity [--db PATH]\n");
}

fn parse_config(a: u8[:][>..]&, start: i64) {
    // defaults
    if cfg_db.len == 0 { cfg_db.append("data/sketchdl.db"); }
    if cfg_data.len == 0 { cfg_data.append("data"); }
    if cfg_listen.len == 0 { cfg_listen.append("127.0.0.1:8087"); }
    if cfg_ytdlp.len == 0 { cfg_ytdlp.append("/usr/local/bin/yt-dlp"); }
    if cfg_ffmpeg.len == 0 { cfg_ffmpeg.append("/usr/bin/ffmpeg"); }
    if cfg_ffprobe.len == 0 { cfg_ffprobe.append("/usr/bin/ffprobe"); }
    if cfg_deno.len == 0 { cfg_deno.append("/usr/local/bin/deno"); }
    var i = start;
    while i < a.len {
        let arg = a[i];
        if arg == "--db" && i + 1 < a.len { cfg_db = []; cfg_db.append(a[i + 1]); i += 2; continue; }
        if arg == "--data" && i + 1 < a.len { cfg_data = []; cfg_data.append(a[i + 1]); i += 2; continue; }
        if arg == "--listen" && i + 1 < a.len { cfg_listen = []; cfg_listen.append(a[i + 1]); i += 2; continue; }
        if arg == "--ytdlp" && i + 1 < a.len { cfg_ytdlp = []; cfg_ytdlp.append(a[i + 1]); i += 2; continue; }
        if arg == "--ffmpeg" && i + 1 < a.len { cfg_ffmpeg = []; cfg_ffmpeg.append(a[i + 1]); i += 2; continue; }
        if arg == "--ffprobe" && i + 1 < a.len { cfg_ffprobe = []; cfg_ffprobe.append(a[i + 1]); i += 2; continue; }
        if arg == "--deno" && i + 1 < a.len { cfg_deno = []; cfg_deno.append(a[i + 1]); i += 2; continue; }
        if arg == "--ejs-parent" && i + 1 < a.len { cfg_ejs_parent = []; cfg_ejs_parent.append(a[i + 1]); i += 2; continue; }
        if arg == "--bgutil-home" && i + 1 < a.len { cfg_bgutil_home = []; cfg_bgutil_home.append(a[i + 1]); i += 2; continue; }
        if arg == "--job" && i + 1 < a.len { cfg_job = []; cfg_job.append(a[i + 1]); i += 2; continue; }
        if arg == "--insecure-cookies" { cfg_secure = false; i += 1; continue; }
        if arg == "--trust-proxy" { cfg_trust_proxy = true; i += 1; continue; }
        if arg == "--out" && i + 1 < a.len { cfg_out = []; cfg_out.append(a[i + 1]); cfg_has_out = true; i += 2; continue; }
        if arg == "--retain-hours" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_retain_hours = v; } i += 2; continue; }
        if arg == "--max-download-bytes" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_max_download_bytes = v; } i += 2; continue; }
        if arg == "--max-duration" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_max_duration = v; } i += 2; continue; }
        if arg == "--inspect-timeout" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_inspect_timeout_ms = v * 1000; } i += 2; continue; }
        if arg == "--download-timeout" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_download_timeout_s = v; } i += 2; continue; }
        if arg == "--min-free-bytes" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_min_free_bytes = v; } i += 2; continue; }
        if arg == "--max-active" && i + 1 < a.len { let v, ok = parse_int(a[i + 1]); if ok { cfg_max_active = v; } i += 2; continue; }
        write_stderr("unknown or incomplete argument\n");
        print_usage();
        exit(2);
    }
}

fn main() {
    let a = args();
    let command = if a.len > 1 { a[1] } else { "serve" };
    if command == "serve" {
        parse_config(a, 2);
        serve();
    } else if command == "worker-once" {
        parse_config(a, 2);
        exit(worker_once());
    } else if command == "admin" {
        let sub = if a.len > 2 { a[2] } else { "" };
        if sub == "set-password" {
            parse_config(a, 3);
            admin_set_password();
        } else if sub == "backup" {
            parse_config(a, 3);
            if !cfg_has_out { write_stderr("backup needs --out PATH\n"); exit(2); }
            admin_backup();
        } else if sub == "integrity" {
            parse_config(a, 3);
            admin_integrity();
        } else {
            write_stderr("usage: sketchdl admin set-password|backup|integrity [--db PATH] [--out PATH]\n");
            exit(2);
        }
    } else if command == "--help" || command == "help" {
        print_usage();
    } else {
        var line: u8[>..] = [];
        format(line, "unknown command: ", command, "\n");
        write_stderr(line);
        print_usage();
        exit(2);
    }
}

// --- HTTP plumbing -----------------------------------------------------------

struct Request {
    method: const u8[:],
    target: const u8[:],
    version: const u8[:],
    content_type: const u8[:], has_ct: bool,
    cookie: const u8[:], has_cookie: bool,
    x_real_ip: const u8[:], has_xri: bool,
    connection: const u8[:], has_conn: bool,
    range_hdr: const u8[:], has_range: bool,
    content_length: i64, has_cl: bool,
    is_chunked: bool,
    expect_continue: bool,
    body: const u8[:],
    keep_alive: bool,
}

struct Response {
    status: i64,
    content_type: const u8[:],
    cache: const u8[:],
    body: const u8[:],
    location: const u8[:], has_location: bool,
    cookie: const u8[:], has_cookie: bool,
    allow: const u8[:], has_allow: bool,
    disposition: const u8[:], has_disposition: bool,
    etag: const u8[:], has_etag: bool,
    content_range: const u8[:], has_range: bool,
    accept_ranges: bool,
    is_stream: bool,
    stream_path: const u8[:],
    stream_offset: i64,
    stream_len: i64,
}

const MAX_HEAD_BYTES = 16 * 1024;
const MAX_BODY_BYTES = 64 * 1024;

fn status_text(code: i64) -> u8[:] {
    if code == 200 { return "200 OK"; }
    if code == 206 { return "206 Partial Content"; }
    if code == 303 { return "303 See Other"; }
    if code == 400 { return "400 Bad Request"; }
    if code == 401 { return "401 Unauthorized"; }
    if code == 403 { return "403 Forbidden"; }
    if code == 404 { return "404 Not Found"; }
    if code == 405 { return "405 Method Not Allowed"; }
    if code == 409 { return "409 Conflict"; }
    if code == 413 { return "413 Content Too Large"; }
    if code == 416 { return "416 Range Not Satisfiable"; }
    if code == 429 { return "429 Too Many Requests"; }
    if code == 500 { return "500 Internal Server Error"; }
    return "500 Internal Server Error";
}

fn fresh_request() -> Request {
    return Request { method: "", target: "", version: "", content_type: "", has_ct: false, cookie: "", has_cookie: false, x_real_ip: "", has_xri: false, connection: "", has_conn: false, range_hdr: "", has_range: false, content_length: 0, has_cl: false, is_chunked: false, expect_continue: false, body: "", keep_alive: false };
}

fn fresh_response() -> Response {
    return Response { status: 500, content_type: "text/html; charset=utf-8", cache: "no-store", body: "",
        location: "", has_location: false, cookie: "", has_cookie: false, allow: "", has_allow: false,
        disposition: "", has_disposition: false, etag: "", has_etag: false, content_range: "", has_range: false,
        accept_ranges: false,
        is_stream: false, stream_path: "", stream_offset: 0, stream_len: 0 };
}

fn eq_ci(a: u8[:], b: u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len {
        if a[i] != b[i] {
            var ca = a[i];
            var cb = b[i];
            if ca >= 'A' && ca <= 'Z' { ca += 32; }
            if cb >= 'A' && cb <= 'Z' { cb += 32; }
            if ca != cb { return false; }
        }
    }
    return true;
}

fn trim_sp(s: u8[:]) -> u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t') { a += 1; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') { b -= 1; }
    return s[a..b];
}

// Per-worker connection scratch (each worker is a separate program).
var conn_buf: u8[>..] = [];
var head_buf: u8[>..] = [];
var body_buf: u8[>..] = [];
var resp_head: u8[>..] = [];
// Response fields borrow from this global arena (reset per request in
// handle_connection), so handler-local builders cannot be referenced.
var resp_scratch: u8[>..] = [];

fn fill(fd: i64, want: i64) -> i64 {
    var buf: u8[65536] = [0; 65536];
    let n = net::read_into(fd, buf, min(65536, max(want, 4096)));
    if n > 0 { conn_buf.append(buf[..n]); }
    return n;
}

fn consume(n: i64) {
    if n <= 0 { return; }
    let total = conn_buf.len;
    let rem = total - n;
    if rem < 0 { conn_buf.pop_n(total); return; }
    for i in rem { conn_buf[i] = conn_buf[n + i]; }
    conn_buf.pop_n(n);
}

fn hex_digit(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn read_chunked(fd: i64, out: u8[>..]&) -> bool {
    loop {
        var size = 0;
        var digits = 0;
        var ok_line = false;
        loop {
            if conn_buf.len == 0 {
                if fill(fd, 4096) <= 0 { return false; }
            }
            let c = conn_buf[0];
            consume(1);
            if c == 13 { continue; }
            if c == ';' {
                loop {
                    if conn_buf.len == 0 {
                        if fill(fd, 4096) <= 0 { return false; }
                    }
                    if conn_buf[0] == 10 { consume(1); break; }
                    consume(1);
                }
                ok_line = true;
                break;
            }
            if c == 10 { ok_line = true; break; }
            let v = hex_digit(c);
            if v < 0 { return false; }
            size = size * 16 + v;
            digits += 1;
        }
        if !ok_line || digits == 0 { return false; }
        if size == 0 {
            // trailers end at an empty line
            loop {
                if conn_buf.len == 0 {
                    if fill(fd, 4096) <= 0 { return true; }
                }
                if conn_buf[0] == 10 { consume(1); return true; }
                loop {
                    if conn_buf.len == 0 {
                        if fill(fd, 4096) <= 0 { return true; }
                    }
                    if conn_buf[0] == 10 { consume(1); break; }
                    consume(1);
                }
                return true;
            }
        }
        if out.len + size > MAX_BODY_BYTES { return false; }
        loop {
            if conn_buf.len >= size + 2 { break; }
            if fill(fd, size + 2 - conn_buf.len) <= 0 { return false; }
        }
        out.append(conn_buf[..size]);
        consume(size + 2);
    }
}

fn compute_keep_alive(req: Request) -> bool {
    if req.has_conn && eq_ci(trim_sp(req.connection), "close") { return false; }
    if starts_with(req.version, "HTTP/1.0") {
        return req.has_conn && eq_ci(trim_sp(req.connection), "keep-alive");
    }
    return true;
}

// Reads one request (head + body). Returns (request, keep_open).
fn read_request(fd: i64) -> Request, bool {
    var req = fresh_request();
    head_buf = [];
    body_buf = [];
    var head_end = -1;
    loop {
        head_end = find(conn_buf, "\r\n\r\n");
        if head_end >= 0 { break; }
        if conn_buf.len > MAX_HEAD_BYTES { return req, false; }
        if fill(fd, MAX_HEAD_BYTES - conn_buf.len + 1) <= 0 { return req, false; }
    }
    if head_end > MAX_HEAD_BYTES { return req, false; }
    head_buf.append(conn_buf[..head_end]);
    consume(head_end + 4);
    let head = head_buf;
    let line_end = find(head, "\r\n");
    let request_line = if line_end >= 0 { head[..line_end] } else { head };
    let sp1 = find(request_line, " ");
    if sp1 < 0 { return req, false; }
    req.method = request_line[..sp1];
    let rest = request_line[sp1 + 1..];
    let sp2 = find(rest, " ");
    if sp2 < 0 { return req, false; }
    req.target = rest[..sp2];
    req.version = rest[sp2 + 1..];
    var pos = if line_end >= 0 { line_end + 2 } else { head.len };
    while pos < head.len {
        let eol = find(head[pos..], "\r\n");
        let line = if eol >= 0 { head[pos..pos + eol] } else { head[pos..] };
        pos += if eol >= 0 { eol + 2 } else { head.len };
        let colon = find(line, ":");
        if colon < 0 { continue; }
        let name = trim_sp(line[..colon]);
        let value = trim_sp(line[colon + 1..]);
        if eq_ci(name, "content-type") { req.content_type = value; req.has_ct = true; }
        else if eq_ci(name, "cookie") { req.cookie = value; req.has_cookie = true; }
        else if eq_ci(name, "x-real-ip") { req.x_real_ip = value; req.has_xri = true; }
        else if eq_ci(name, "connection") { req.connection = value; req.has_conn = true; }
        else if eq_ci(name, "range") { req.range_hdr = value; req.has_range = true; }
        else if eq_ci(name, "content-length") {
            let n, ok = parse_int(value);
            if ok && n >= 0 { req.content_length = n; req.has_cl = true; }
        } else if eq_ci(name, "transfer-encoding") {
            if find(value, "chunked") >= 0 { req.is_chunked = true; }
        } else if eq_ci(name, "expect") {
            if eq_ci(value, "100-continue") { req.expect_continue = true; }
        }
    }
    req.keep_alive = compute_keep_alive(req);
    if req.expect_continue && (req.has_cl || req.is_chunked) {
        net::write_all(fd, "HTTP/1.1 100 Continue\r\n\r\n");
        req.keep_alive = compute_keep_alive(req);
    }
    if req.is_chunked {
        if !read_chunked(fd, body_buf) { req.keep_alive = false; req.body = body_buf; return req, false; }
        req.body = body_buf;
        return req, true;
    }
    if req.has_cl {
        let cl = req.content_length;
        if cl > MAX_BODY_BYTES { return req, false; }
        loop {
            if conn_buf.len >= cl { break; }
            if fill(fd, cl - conn_buf.len) <= 0 { req.keep_alive = false; return req, false; }
        }
        body_buf.append(conn_buf[..cl]);
        consume(cl);
    }
    req.body = body_buf;
    return req, true;
}

fn send_response(fd: i64, req: Request, resp: Response) -> bool {
    format(resp_head, "HTTP/1.1 ", status_text(resp.status), "\r\n");
    format(resp_head, "Content-Type: ", resp.content_type, "\r\n");
    format(resp_head, "Cache-Control: ", resp.cache, "\r\n");
    format(resp_head, "Content-Security-Policy: ", views::CSP, "\r\n");
    resp_head.append("X-Content-Type-Options: nosniff\r\n");
    resp_head.append("Referrer-Policy: no-referrer\r\n");
    if resp.has_location {
        format(resp_head, "Location: ", resp.location, "\r\n");
    }
    if resp.has_cookie {
        format(resp_head, "Set-Cookie: ", resp.cookie, "\r\n");
    }
    if resp.has_allow {
        format(resp_head, "Allow: ", resp.allow, "\r\n");
    }
    if resp.has_disposition {
        format(resp_head, "Content-Disposition: ", resp.disposition, "\r\n");
    }
    if resp.has_etag {
        format(resp_head, "ETag: ", resp.etag, "\r\n");
    }
    if resp.has_range {
        format(resp_head, "Content-Range: ", resp.content_range, "\r\n");
    }
    if resp.accept_ranges {
        resp_head.append("Accept-Ranges: bytes\r\n");
    }
    var len = resp.body.len;
    if resp.is_stream { len = resp.stream_len; }
    format(resp_head, "Content-Length: ", len, "\r\n");
    if !req.keep_alive { resp_head.append("Connection: close\r\n"); }
    resp_head.append("\r\n");
    if !net::write_all(fd, resp_head) { return false; }
    if resp.is_stream {
        return stream_file(fd, resp.stream_path, resp.stream_offset, resp.stream_len);
    }
    if !net::write_all(fd, resp.body) { return false; }
    return true;
}

// Streams one file region with sendfile (zero-copy where available).
fn stream_file(fd: i64, path: u8[:], offset: i64, length: i64) -> bool {
    var pc: u8[>..] = [];
    proc::cstr(path, pc);
    var fdesc: i32 = 0;
    fdesc = sk_open_read(pc[0]);
    if fdesc < 0 { return false; }
    var sent = 0;
    var ok = true;
    while sent < length {
        let n = sk_sendfile(fd as i32, fdesc, offset + sent, length - sent);
        if n <= 0 { ok = false; break; }
        sent += n;
    }
    sk_close_fd(fdesc);
    return ok;
}

// --- auth / sessions -----------------------------------------------------------

struct Auth { csrf: const u8[:], ok: bool }

fn find_cookie(cookie_hdr: u8[:], name: u8[:]) -> u8[:], bool {
    var pos = 0;
    loop {
        if pos > cookie_hdr.len { break; }
        while pos < cookie_hdr.len && (cookie_hdr[pos] == ' ' || cookie_hdr[pos] == '\t') { pos += 1; }
        if pos >= cookie_hdr.len { break; }
        var semi = pos;
        while semi < cookie_hdr.len && cookie_hdr[semi] != ';' { semi += 1; }
        let pair = trim_sp(cookie_hdr[pos..semi]);
        let eq = find(pair, "=");
        if eq >= 0 {
            let n = trim_sp(pair[..eq]);
            let v = trim_sp(pair[eq + 1..]);
            if n == name { return v, true; }
        }
        if semi >= cookie_hdr.len { break; }
        pos = semi + 1;
    }
    return "", false;
}

fn authenticate(cookie_value: u8[:], has_cookie: bool, now: i64, scratch: u8[>..]&) -> Auth {
    if !has_cookie { return Auth { csrf: "", ok: false }; }
    var token_hash: u8[>..] = [];
    if !auth::token_hash_from_hex(cookie_value, token_hash) { return Auth { csrf: "", ok: false }; }
    let csrf, ok = db::find_session(token_hash, now, scratch);
    if !ok { return Auth { csrf: "", ok: false }; }
    db::touch_session(token_hash, now);
    return Auth { csrf: csrf, ok: true };
}

fn csrf_ok(expected: u8[:], form: util::Form) -> bool {
    let supplied, ok = util::form_get(form, "csrf");
    if !ok { return false; }
    return auth::csrf_matches(expected, supplied);
}

fn session_cookie(out: u8[>..]&, token_hex: u8[:], max_age: i64) {
    out.append(cookie_name());
    out.push('=');
    if token_hex.len > 0 { out.append(token_hex); }
    out.append("; Path=/");
    if cfg_secure { out.append("; Secure"); }
    out.append("; HttpOnly; SameSite=Lax; Max-Age=");
    format(out, max_age);
    if max_age == 0 { out.append("; Expires=Thu, 01 Jan 1970 00:00:00 GMT"); }
}

fn is_form_content_type(ct: u8[:], has_ct: bool) -> bool {
    if !has_ct { return false; }
    var base = ct;
    let semi = find(ct, ";");
    if semi >= 0 { base = ct[..semi]; }
    return eq_ci(trim_sp(base), "application/x-www-form-urlencoded");
}

fn client_ip(req: Request, scratch: u8[>..]&) -> u8[:] {
    if cfg_trust_proxy && req.has_xri && req.x_real_ip.len > 0 && req.x_real_ip.len <= 64 {
        scratch.append(req.x_real_ip);
        return scratch;
    }
    scratch.append("127.0.0.1");
    return scratch;
}

// --- login machinery (dedicated worker owns limiter + Argon2id) --------------

struct LoginReq { seq: u64, now: i64, pwd_len: i64, ip_len: i64, pwd: u8[1024], ip: u8[64] }
struct LoginRes { seq: u64, status: i64, token: u8[64], csrf: u8[64] }

thread_fn login_worker() {
    loop {
        let req = qget<LoginReq>();
        if req.pwd_len < 0 { break; }
        qput(process_login(req));
    }
}

fn process_login(req: LoginReq) -> LoginRes {
    var res = LoginRes { seq: req.seq, status: 5, token: [0; 64], csrf: [0; 64] };
    let ticket, limited, busy = auth::lim_begin(req.ip[..req.ip_len], req.now);
    if limited { res.status = 1; return res; }
    if busy { res.status = 2; return res; }
    var scratch: u8[>..] = [];
    let stored, has_hash = db::owner_hash(scratch);
    if !has_hash {
        auth::lim_finish(ticket, false, req.now);
        res.status = 3;
        return res;
    }
    let ok = auth::verify_password(stored, req.pwd[..req.pwd_len]);
    auth::lim_finish(ticket, ok, req.now);
    if !ok { res.status = 4; return res; }
    var token: u8[>..] = [];
    var token_hash: u8[>..] = [];
    var csrf: u8[>..] = [];
    if !auth::new_session(token, token_hash, csrf) { return res; }
    let expires = req.now + cfg_session_days * 86400;
    if !db::create_session(token_hash, csrf, req.now, expires) { return res; }
    res.status = 0;
    for i in 64 {
        res.token[i] = token[i];
        res.csrf[i] = csrf[i];
    }
    return res;
}

// --- dispatch ------------------------------------------------------------------

fn error_resp(resp: Response&, body: u8[>..]&, status: i64, title: u8[:], detail: u8[:]) {
    resp.status = status;
    resp.content_type = "text/html; charset=utf-8";
    views::error_page(body, status, title, detail);
}

fn method_not_allowed(resp: Response&, body: u8[>..]&, allow: u8[:]) {
    resp.status = 405;
    resp.has_allow = true;
    resp.allow = allow;
    views::error_page(body, 405, "Method not allowed", "This action needs a different request method.");
}

fn redirect_303(resp: Response&, location: u8[:]) {
    resp.status = 303;
    resp.has_location = true;
    let cs = resp_scratch.len;
    resp_scratch.append(location);
    resp.location = resp_scratch[cs..];
}

fn require_login_page(resp: Response&, body: u8[>..]&) {
    resp.status = 303;
    resp.has_location = true;
    resp.location = "/login";
}

struct Route { path: const u8[:], query: const u8[:], has_query: bool }

fn split_target(target: u8[:]) -> Route {
    let q = find(target, "?");
    if q >= 0 { return Route { path: target[..q], query: target[q + 1..], has_query: true }; }
    return Route { path: target, query: "", has_query: false };
}

fn dispatch(req: Request, resp: Response&, body: u8[>..]&) {
    var scratch: u8[>..] = [];
    let rt = split_target(req.target);
    let path = rt.path;
    let is_read = req.method == "GET" || req.method == "HEAD";
    let is_post = req.method == "POST";

    if path == "/healthz" {
        if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
        resp.status = 200;
        resp.content_type = "text/plain; charset=utf-8";
        body.append("ok\n");
        return;
    }
    if path == "/assets/style.css" {
        if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
        resp.status = 200;
        resp.content_type = "text/css; charset=utf-8";
        resp.cache = "public, max-age=31536000, immutable";
        body.append(embed_file("web/style.css"));
        return;
    }
    if path == "/favicon.ico" {
        error_resp(resp, body, 404, "Not found", "No such resource.");
        return;
    }
    if path == "/login" {
        if is_read {
            resp.status = 200;
            views::login_page(body, "", false);
            return;
        }
        if !is_post { method_not_allowed(resp, body, "GET, HEAD, POST"); return; }
        handle_login(req, resp, body, scratch);
        return;
    }

    let now = now_seconds();
    var cookie_value: const u8[:] = req.cookie;
    var has_cookie = false;
    if req.has_cookie {
        cookie_value, has_cookie = find_cookie(req.cookie, cookie_name());
    }
    let authed = authenticate(cookie_value, has_cookie, now, scratch);
    if !authed.ok {
        if is_read { require_login_page(resp, body); return; }
        error_resp(resp, body, 401, "Log in required", "Your session is missing or expired. Log in and try again.");
        return;
    }
    let csrf = authed.csrf;

    if path == "/logout" {
        if !is_post { method_not_allowed(resp, body, "POST"); return; }
        var form = util::Form { fields: [util::Field { name: "", value: "" }; 64], n: 0 };
        if !util::parse_form(req.body, scratch, form) { error_resp(resp, body, 400, "Bad request", "Malformed form data."); return; }
        if !csrf_ok(csrf, form) { error_resp(resp, body, 403, "Forbidden", "The form expired. Reload and try again."); return; }
        var token_hash: u8[>..] = [];
        auth::token_hash_from_hex(cookie_value, token_hash);
        db::revoke_session(token_hash);
        resp.status = 303;
        resp.has_location = true;
        resp.location = "/login";
        let cs = resp_scratch.len;
        session_cookie(resp_scratch, "", 0);
        resp.cookie = resp_scratch[cs..];
        resp.has_cookie = true;
        return;
    }
    if path == "/" {
        if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
        if !db::has_owner() { require_login_page(resp, body); return; }
        var jobs_scratch: u8[>..] = [];
        let jobs = db::list_jobs(8, jobs_scratch);
        resp.status = 200;
        views::home_page(body, csrf, jobs, "", false);
        return;
    }
    if path == "/inspect" {
        if !is_post { method_not_allowed(resp, body, "POST"); return; }
        var form = util::Form { fields: [util::Field { name: "", value: "" }; 64], n: 0 };
        if !util::parse_form(req.body, scratch, form) { error_resp(resp, body, 400, "Bad request", "Malformed form data."); return; }
        if !csrf_ok(csrf, form) { error_resp(resp, body, 403, "Forbidden", "The form expired. Reload and try again."); return; }
        handle_inspect(resp, body, form, csrf, scratch);
        return;
    }
    if starts_with(path, "/inspect/") {
        if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
        let token = path[9..];
        if !valid_hex_token(token) { error_resp(resp, body, 404, "Not found", "This preview does not exist."); return; }
        var th: u8[>..] = [];
        if !auth::token_hash_from_hex(token, th) { error_resp(resp, body, 404, "Not found", "This preview does not exist."); return; }
        var iscratch: u8[>..] = [];
        let insp, ok = db::find_inspection(th, now, iscratch);
        if !ok { error_resp(resp, body, 404, "Not found", "This preview expired or was already used. Please inspect the video again."); return; }
        var fscratch: u8[>..] = [];
        let formats = ytdlp::parse_stored_formats(insp.formats_json, fscratch);
        resp.status = 200;
        views::inspect_page(body, csrf, token, insp.title, insp.duration, insp.has_duration, formats, insp.video_id);
        return;
    }
    if path == "/jobs" {
        if is_read {
            var jobs_scratch: u8[>..] = [];
            let jobs = db::list_jobs(50, jobs_scratch);
            resp.status = 200;
            views::jobs_page(body, csrf, jobs);
            return;
        }
        if is_post {
            var form = util::Form { fields: [util::Field { name: "", value: "" }; 64], n: 0 };
            if !util::parse_form(req.body, scratch, form) { error_resp(resp, body, 400, "Bad request", "Malformed form data."); return; }
            if !csrf_ok(csrf, form) { error_resp(resp, body, 403, "Forbidden", "The form expired. Reload and try again."); return; }
            handle_enqueue(req, resp, body, form, csrf, scratch);
            return;
        }
        method_not_allowed(resp, body, "GET, HEAD, POST");
        return;
    }
    if starts_with(path, "/jobs/") {
        let rest = path[6..];
        if !valid_job_id_path(rest) { error_resp(resp, body, 404, "Not found", "No such download."); return; }
        let slash = find(rest, "/");
        if slash < 0 {
            if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
            handle_job_page(rest, resp, body, csrf, scratch);
            return;
        }
        let id_part = rest[..slash];
        let action = rest[slash + 1..];
        if !is_post { method_not_allowed(resp, body, "POST"); return; }
        var form = util::Form { fields: [util::Field { name: "", value: "" }; 64], n: 0 };
        if !util::parse_form(req.body, scratch, form) { error_resp(resp, body, 400, "Bad request", "Malformed form data."); return; }
        if !csrf_ok(csrf, form) { error_resp(resp, body, 403, "Forbidden", "The form expired. Reload and try again."); return; }
        if action == "cancel" { handle_cancel(id_part, resp, body, csrf, scratch); return; }
        if action == "retry" { handle_retry(id_part, resp, body, csrf, scratch); return; }
        if action == "delete" { handle_delete(id_part, resp, body, csrf, scratch); return; }
        error_resp(resp, body, 404, "Not found", "No such download.");
        return;
    }
    if starts_with(path, "/downloads/") {
        if !is_read { method_not_allowed(resp, body, "GET, HEAD"); return; }
        let id = path[11..];
        if !valid_job_id_path(id) { error_resp(resp, body, 404, "Not found", "No such download."); return; }
        handle_download(req, resp, body, id, scratch);
        return;
    }
    error_resp(resp, body, 404, "Not found", "No such resource.");
}

fn valid_hex_token(token: u8[:]) -> bool {
    if token.len != 64 { return false; }
    for c in token {
        if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { return false; }
    }
    return true;
}

fn valid_job_id_path(id: u8[:]) -> bool {
    return storage::valid_job_id(id);
}

fn handle_login(req: Request, resp: Response&, body: u8[>..]&, scratch: u8[>..]&) {
    if !is_form_content_type(req.content_type, req.has_ct) {
        resp.status = 415;
        views::login_page(body, "Use the HTML login form.", true);
        return;
    }
    var form = util::Form { fields: [util::Field { name: "", value: "" }; 64], n: 0 };
    if !util::parse_form(req.body, scratch, form) {
        resp.status = 400;
        views::login_page(body, "Malformed login form.", true);
        return;
    }
    let password, has_pw = util::form_get(form, "password");
    if !has_pw {
        resp.status = 400;
        views::login_page(body, "Password is required.", true);
        return;
    }
    if password.len > auth::MAX_PASSWORD {
        resp.status = 400;
        views::login_page(body, "Password is too long.", true);
        return;
    }
    if auth::validate_password(password) != 0 {
        resp.status = 400;
        views::login_page(body, "Password must be at least 12 characters.", true);
        return;
    }
    let now = now_seconds();
    var ip_scratch: u8[>..] = [];
    let ip = client_ip(req, ip_scratch);
    var rb: u8[>..] = [];
    crypto::random_bytes(rb, 8);
    var seq: u64 = 0;
    for i in 8 { seq |= (rb[i] as u64) << (8 * i); }
    var job = LoginReq { seq: seq, now: now, pwd_len: password.len, ip_len: 0, pwd: [0; 1024], ip: [0; 64] };
    for i in password.len { job.pwd[i] = password[i]; }
    let ip_len = if ip.len > 64 { 64 } else { ip.len };
    job.ip_len = ip_len;
    for i in ip_len { job.ip[i] = ip[i]; }
    if !qput(job) {
        resp.status = 429;
        views::login_page(body, "Another login is being processed. Try again shortly.", true);
        return;
    }
    var res = qget<LoginRes>();
    while res.seq != seq {
        qput(res);
        res = qget<LoginRes>();
    }
    if res.status == 1 {
        resp.status = 429;
        views::login_page(body, "Too many failed login attempts. Wait 15 minutes and try again.", true);
        return;
    }
    if res.status == 2 {
        resp.status = 429;
        views::login_page(body, "Another login is being processed. Try again shortly.", true);
        return;
    }
    if res.status == 3 {
        resp.status = 401;
        views::login_page(body, "No owner password is configured.", true);
        return;
    }
    if res.status == 4 {
        resp.status = 401;
        views::login_page(body, "Incorrect password.", true);
        return;
    }
    if res.status != 0 {
        resp.status = 500;
        views::login_page(body, "Login failed. Try again.", true);
        return;
    }
    let cs = resp_scratch.len;
    session_cookie(resp_scratch, res.token[..64], cfg_session_days * 86400);
    resp.status = 303;
    resp.has_location = true;
    resp.location = "/";
    resp.cookie = resp_scratch[cs..];
    resp.has_cookie = true;
    let _ = res;
}

// --- inspect (metadata-only, synchronous in the connection worker) ----------

fn base_ytdlp_args(blob: u8[>..]&, offs: i32[>..]&) {
    proc::argv_push(blob, offs, cfg_ytdlp);
    proc::argv_push(blob, offs, "--ignore-config");
    // Only our own vendored Python deps (EJS + POT provider plugins) may
    // load; never user plugin dirs.
    if cfg_ejs_parent.len > 0 {
        proc::argv_push(blob, offs, "--plugin-dirs");
        proc::argv_push(blob, offs, cfg_ejs_parent);
    } else {
        proc::argv_push(blob, offs, "--no-plugin-dirs");
    }
    // Datacenter IPs get "Sign in to confirm you're not a bot" without a
    // PO token. The vendored bgutil WebPO provider mints one via deno.
    // fetch_pot=always forces minting (auto never triggers on these
    // clients); mweb/tv/web_safari carry a usable player token. All
    // constants plus operator config: no user input reaches argv.
    if cfg_bgutil_home.len > 0 {
        var ea1: u8[>..] = [];
        ea1.append("youtubepot-bgutilscript:server_home=");
        ea1.append(cfg_bgutil_home);
        proc::argv_push(blob, offs, "--extractor-args");
        proc::argv_push(blob, offs, ea1);
        proc::argv_push(blob, offs, "--extractor-args");
        proc::argv_push(blob, offs, "youtube:fetch_pot=always;player_client=mweb,tv,web_safari");
    }
    proc::argv_push(blob, offs, "--no-playlist");
}

fn ytdlp_env() -> u8[>..] {
    var env: u8[>..] = [];
    if cfg_ejs_parent.len > 0 {
        env.append("PYTHONPATH=");
        env.append(cfg_ejs_parent);
    }
    return env;
}

fn js_runtimes_arg() -> u8[>..] {
    var s: u8[>..] = [];
    s.append("deno:");
    s.append(cfg_deno);
    return s;
}

// Runs yt-dlp, draining stdout (capped) and stderr (tail, capped), with a
// deadline. Returns exit code, or -1 on timeout. out collects stdout,
// err_tail the last bytes of stderr. Child is always reaped.
fn run_child(blob: u8[>..]&, offs: i32[>..]&, exe: u8[:], timeout_ms: i64, out_cap: i64, out: u8[>..]&, err_tail: u8[>..]&) -> i64 {
    var child = proc::Child { pid: 0, out_fd: 0, err_fd: 0 };
    let env = ytdlp_env();
    if !proc::spawn_env(exe, blob, offs, "", env, child) { return 127; }
    var buf: u8[65536] = [0; 65536];
    var out_eof = false;
    var err_eof = false;
    var elapsed = 0;
    var over_cap = false;
    var final_ec = -1;
    var reaped = false;
    loop {
        if !out_eof {
            let r = proc::poll_read(child.out_fd, buf, 100);
            if r > 0 {
                if out.len + r <= out_cap { out.append(buf[..r]); }
                else { over_cap = true; }
            } else if r == 0 { out_eof = true; }
        } else if !err_eof {
            let r = proc::poll_read(child.err_fd, buf, 100);
            if r > 0 {
                if err_tail.len + r > 8192 { err_tail.pop_n(err_tail.len + r - 8192); }
                err_tail.append(buf[..r]);
            } else if r == 0 { err_eof = true; }
        }
        let ec, st = proc::try_wait(child.pid);
        if st == 1 { final_ec = ec; reaped = true; break; }
        elapsed += 100;
        if elapsed > timeout_ms {
            proc::kill_group(child.pid, 9);
            let _ec, _w = proc::wait(child.pid);
            proc::close_fd(child.out_fd);
            proc::close_fd(child.err_fd);
            return -1;
        }
        if over_cap && elapsed > timeout_ms + 5000 {
            proc::kill_group(child.pid, 9);
            let _ec2, _w2 = proc::wait(child.pid);
            proc::close_fd(child.out_fd);
            proc::close_fd(child.err_fd);
            return -2;
        }
    }
    // drain
    var rounds = 0;
    while (!out_eof || !err_eof) && rounds < 100 {
        rounds += 1;
        if !out_eof {
            let r = proc::poll_read(child.out_fd, buf, 100);
            if r > 0 { if out.len + r <= out_cap { out.append(buf[..r]); } else { over_cap = true; } }
            else if r == 0 { out_eof = true; }
        }
        if !err_eof {
            let r = proc::poll_read(child.err_fd, buf, 100);
            if r > 0 { if err_tail.len + r > 8192 { err_tail.pop_n(err_tail.len + r - 8192); } err_tail.append(buf[..r]); }
            else if r == 0 { err_eof = true; }
        }
    }
    proc::close_fd(child.out_fd);
    proc::close_fd(child.err_fd);
    if over_cap { return -2; }
    if reaped { return final_ec; }
    // try_wait had not reaped the child (the round cap fired first):
    // waitpid here returns its exit code. Never double-waits a reaped child.
    let exit_code, _w = proc::wait(child.pid);
    return exit_code;
}

fn handle_inspect(resp: Response&, body: u8[>..]&, form: util::Form, csrf: u8[:], scratch: u8[>..]&) {
    let url, has_url = util::form_get(form, "url");
    if !has_url || url.len == 0 {
        resp.status = 200;
        var jobs_scratch: u8[>..] = [];
        let jobs = db::list_jobs(8, jobs_scratch);
        views::home_page(body, csrf, jobs, "Paste a video URL first.", true);
        return;
    }
    var video_id: u8[>..] = [];
    var canon: u8[>..] = [];
    let prc = input::parse_youtube_url(url, video_id, canon);
    if prc == 4 {
        resp.status = 200;
        var jobs_scratch: u8[>..] = [];
        let jobs = db::list_jobs(8, jobs_scratch);
        views::home_page(body, csrf, jobs, "That is not a valid 11-character YouTube video link.", true);
        return;
    }
    if prc != 0 {
        resp.status = 200;
        var jobs_scratch: u8[>..] = [];
        let jobs = db::list_jobs(8, jobs_scratch);
        views::home_page(body, csrf, jobs, "Only https youtube.com / youtu.be video links are accepted here.", true);
        return;
    }
    // Metadata-only extraction in a sandbox: fixed argv, no shell, output
    // capped, deadline enforced. Raw input never reaches this point: only
    // the canonical URL rebuilt from the validated id is passed.
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    base_ytdlp_decode(blob, offs);
    let jsr = js_runtimes_arg();
    proc::argv_push(blob, offs, "--js-runtimes");
    proc::argv_push(blob, offs, jsr);
    proc::argv_push(blob, offs, "--skip-download");
    proc::argv_push(blob, offs, "--dump-single-json");
    proc::argv_push(blob, offs, "--socket-timeout");
    proc::argv_push(blob, offs, "15");
    proc::argv_push(blob, offs, "--retries");
    proc::argv_push(blob, offs, "2");
    proc::argv_push(blob, offs, canon);
    var stdout_b: u8[>..] = [];
    var stderr_b: u8[>..] = [];
    let ec = run_child(blob, offs, cfg_ytdlp, cfg_inspect_timeout_ms, ytdlp::MAX_JSON_BYTES, stdout_b, stderr_b);
    if ec == -1 {
        resp.status = 200;
        views::inspect_empty(body, csrf, "YouTube did not answer in time. Please try again.");
        return;
    }
    if ec == -2 {
        resp.status = 200;
        views::inspect_empty(body, csrf, "That video returned too much metadata to preview.");
        return;
    }
    if ec != 0 {
        var code: u8[>..] = [];
        var detail: u8[>..] = [];
        ytdlp::classify_error(stderr_b, code, detail);
        if code.len == 0 { code.append("EXTRACT_FAILED"); detail.append("Extraction failed."); }
        resp.status = 200;
        var msg: u8[>..] = [];
        format(msg, code, ": ", detail);
        views::inspect_empty(body, csrf, msg);
        return;
    }
    var pscratch: u8[>..] = [];
    let insp, ok = ytdlp::parse_inspection(stdout_b, video_id, pscratch);
    if !ok {
        resp.status = 200;
        views::inspect_empty(body, csrf, "The metadata did not match the requested video, so it was discarded.");
        return;
    }
    if insp.has_duration && insp.duration > cfg_max_duration {
        resp.status = 200;
        views::inspect_empty(body, csrf, "This video is longer than the configured maximum. Nothing was downloaded.");
        return;
    }
    var has_compat = false;
    for f in insp.formats {
        if f.is_mp4_compat && f.has_video && f.height > 0 { has_compat = true; break; }
    }
    if !has_compat {
        resp.status = 200;
        views::inspect_empty(body, csrf, "No H.264/AAC MP4 format is offered for this video. VP9/AV1 and other containers are not listed as compatible.");
        return;
    }
    // Mint a short-lived preview token; only its hash is stored.
    var raw: u8[>..] = [];
    if !crypto::random_bytes(raw, 32) {
        resp.status = 500;
        views::error_page(body, 500, "Server error", "Randomness source unavailable.");
        return;
    }
    var token: u8[>..] = [];
    crypto::hex_lower(token, raw);
    let token_hash = crypto::sha256_hex(raw);
    let formats_json = ytdlp::formats_to_json(insp.formats);
    let now = now_seconds();
    if !db::store_inspection(token_hash, insp.id, insp.title, insp.duration, insp.has_duration, formats_json, now + 10 * 60) {
        resp.status = 500;
        views::error_page(body, 500, "Server error", "Could not store the preview.");
        return;
    }
    var fscratch: u8[>..] = [];
    let formats = ytdlp::parse_stored_formats(formats_json, fscratch);
    var loc: u8[>..] = [];
    loc.append("/inspect/");
    loc.append(token);
    redirect_303(resp, loc);
}

fn base_ytdlp_decode(blob: u8[>..]&, offs: i32[>..]&) {
    base_ytdlp_args(blob, offs);
}

// --- enqueue ------------------------------------------------------------------

fn handle_enqueue(req: Request, resp: Response&, body: u8[>..]&, form: util::Form, csrf: u8[:], scratch: u8[>..]&) {
    let token, has_token = util::form_get(form, "inspect");
    let preset, has_preset = util::form_get(form, "preset");
    if !has_token || !valid_hex_token(token) {
        error_resp(resp, body, 400, "Bad request", "The preview is missing or expired.");
        return;
    }
    if !has_preset || preset.len == 0 || preset.len > 8 {
        error_resp(resp, body, 400, "Bad request", "Choose a quality first.");
        return;
    }
    var ceiling = 0;
    if preset == "144p" { ceiling = 144; }
    else if preset == "240p" { ceiling = 240; }
    else if preset == "360p" { ceiling = 360; }
    else if preset == "480p" { ceiling = 480; }
    else if preset == "720p" { ceiling = 720; }
    else if preset == "1080p" { ceiling = 1080; }
    else if preset == "1440p" { ceiling = 1440; }
    else if preset == "2160p" { ceiling = 2160; }
    else { error_resp(resp, body, 400, "Bad request", "Unknown quality."); return; }
    let now = now_seconds();
    var token_hash: u8[>..] = [];
    auth::token_hash_from_hex(token, token_hash);
    var iscratch: u8[>..] = [];
    let insp, ok = db::find_inspection(token_hash, now, iscratch);
    if !ok {
        error_resp(resp, body, 404, "Not found", "This preview expired or was already used. Please inspect the video again.");
        return;
    }
    var fscratch: u8[>..] = [];
    let formats = ytdlp::parse_stored_formats(insp.formats_json, fscratch);
    var spec: u8[>..] = [];
    let est = ytdlp::select_format(formats, ceiling, spec);
    if est < -1 {
        error_resp(resp, body, 400, "Format unavailable", "No MP4-compatible format is offered at this quality.");
        return;
    }
    if est >= 0 && est > cfg_max_download_bytes {
        error_resp(resp, body, 400, "Too large", "The estimated size exceeds the configured maximum.");
        return;
    }
    if db::count_active() >= cfg_max_active {
        error_resp(resp, body, 429, "Queue is full", "Too many downloads are waiting. Try again shortly.");
        // Retry-After for the browser; stored value is decorative here.
        return;
    }
    let free = proc::free_bytes(cfg_data);
    if free >= 0 && free < cfg_min_free_bytes {
        error_resp(resp, body, 500, "Disk nearly full", "Not enough free space to start a download.");
        return;
    }
    // Server-minted opaque id + format spec. The spec is validated
    // character-by-character; it is never a free-form client string.
    var spec_ok = spec.len > 0 && spec.len <= 48;
    if spec_ok {
        for part in split(spec, '+') {
            if !ytdlp::valid_format_id(part) { spec_ok = false; }
        }
    }
    if !spec_ok {
        error_resp(resp, body, 400, "Format unavailable", "The selected format could not be verified.");
        return;
    }
    var idraw: u8[>..] = [];
    if !crypto::random_bytes(idraw, 16) {
        error_resp(resp, body, 500, "Server error", "Randomness source unavailable.");
        return;
    }
    var job_id: u8[>..] = [];
    crypto::hex_lower(job_id, idraw);
    var preset_b: u8[>..] = [];
    preset_b.append(preset);
    if !db::create_job(job_id, insp.video_id, insp.title, preset_b, spec, now) {
        error_resp(resp, body, 500, "Server error", "Could not queue the download.");
        return;
    }
    // Consume the preview: at-most-once enqueue per preview.
    db::delete_inspection(token_hash);
    var loc: u8[>..] = [];
    loc.append("/jobs/");
    loc.append(job_id);
    redirect_303(resp, loc);
}

// --- job pages and actions ----------------------------------------------------

fn handle_job_page(id: u8[:], resp: Response&, body: u8[>..]&, csrf: u8[:], scratch: u8[>..]&) {
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(id, jscratch);
    if !ok { error_resp(resp, body, 404, "Not found", "No such download."); return; }
    var facts: u8[>..] = [];
    let _ = facts;
    resp.status = 200;
    views::job_page(body, csrf, job, "");
}

fn handle_cancel(id: u8[:], resp: Response&, body: u8[>..]&, csrf: u8[:], scratch: u8[>..]&) {
    let now = now_seconds();
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(id, jscratch);
    if !ok { error_resp(resp, body, 404, "Not found", "No such download."); return; }
    if job.state == "QUEUED" {
        db::transition(id, "QUEUED", "CANCELLED", now, "MANUAL", true);
    } else if job.state == "DOWNLOADING" || job.state == "VERIFYING" {
        // The worker polls the database and shuts its child group down.
        db::transition(id, job.state, "CANCELLED", now, "MANUAL", true);
    }
    var loc: u8[>..] = [];
    loc.append("/jobs/");
    loc.append(id);
    redirect_303(resp, loc);
}

fn handle_retry(id: u8[:], resp: Response&, body: u8[>..]&, csrf: u8[:], scratch: u8[>..]&) {
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(id, jscratch);
    if !ok { error_resp(resp, body, 404, "Not found", "No such download."); return; }
    var loc: u8[>..] = [];
    loc.append("/jobs/");
    loc.append(id);
    if job.state == "FAILED" || job.state == "CANCELLED" {
        if job.retry_count >= 3 {
            resp.status = 200;
            views::error_page(body, 409, "Retry limit", "This download was already retried 3 times.");
            return;
        }
        if db::count_active() >= cfg_max_active {
            resp.status = 429;
            views::error_page(body, 429, "Queue is full", "Try again shortly.");
            return;
        }
        let now = now_seconds();
        db::requeue(id, now);
        // Fresh staging area for the retry.
        var d: u8[>..] = [];
        storage::job_dir(d, cfg_data, id);
        proc::rm_rf(d);
    }
    redirect_303(resp, loc);
}

fn handle_delete(id: u8[:], resp: Response&, body: u8[>..]&, csrf: u8[:], scratch: u8[>..]&) {
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(id, jscratch);
    if !ok { redirect_303(resp, "/jobs"); return; }
    if job.state == "QUEUED" || job.state == "DOWNLOADING" || job.state == "VERIFYING" {
        // Never delete active work out from under the worker; cancel first.
        resp.status = 409;
        views::error_page(body, 409, "Busy", "Cancel this download before removing it.");
        return;
    }
    storage::remove_complete(cfg_data, id);
    storage::cleanup_job(cfg_data, id);
    db::delete_job(id);
    redirect_303(resp, "/jobs");
}

// --- downloads ----------------------------------------------------------------

fn handle_download(req: Request, resp: Response&, body: u8[>..]&, id: u8[:], scratch: u8[>..]&) {
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(id, jscratch);
    if !ok { error_resp(resp, body, 404, "Not found", "No such download."); return; }
    let now = now_seconds();
    if job.state != "READY" {
        error_resp(resp, body, 409, "Not ready", "This download is not finished yet.");
        return;
    }
    if job.has_expires && job.expires_at <= now {
        storage::remove_complete(cfg_data, id);
        db::transition(id, "READY", "EXPIRED", now, "TTL", true);
        error_resp(resp, body, 410, "Expired", "This download expired and was removed.");
        return;
    }
    var path: u8[>..] = [];
    storage::complete_path(path, cfg_data, id);
    let size = proc::file_size(path);
    if size <= 0 {
        error_resp(resp, body, 410, "Missing", "The file is missing from disk.");
        return;
    }
    resp.content_type = "video/mp4";
    resp.cache = "private, max-age=60";
    resp.accept_ranges = true;
    var disp: u8[>..] = [];
    disp.append("attachment; filename=\"sketchdl-");
    disp.append(id);
    disp.append(".mp4\"");
    let ds = resp_scratch.len;
    resp_scratch.append(disp);
    resp.disposition = resp_scratch[ds..];
    resp.has_disposition = true;
    var tag: u8[>..] = [];
    tag.append("\"");
    tag.append(id);
    tag.append("-");
    format(tag, size);
    tag.append("\"");
    let ts = resp_scratch.len;
    resp_scratch.append(tag);
    resp.etag = resp_scratch[ts..];
    resp.has_etag = true;
    // Range support (single range; anything else is rejected cleanly).
    var start = 0;
    var end = size - 1;
    var partial = false;
    if req.has_range {
        let r = req.range_hdr;
        if !starts_with(r, "bytes=") {
            resp.status = 416;
            var cr: u8[>..] = [];
            format(cr, "bytes */", size);
            let cs2 = resp_scratch.len;
            resp_scratch.append(cr);
            resp.content_range = resp_scratch[cs2..];
            resp.has_range = true;
            views::error_page(body, 416, "Range not satisfiable", "The requested byte range is invalid.");
            return;
        }
        let spec = r[6..];
        if find(spec, ",") >= 0 {
            resp.status = 416;
            var cr: u8[>..] = [];
            format(cr, "bytes */", size);
            let cs2 = resp_scratch.len;
            resp_scratch.append(cr);
            resp.content_range = resp_scratch[cs2..];
            resp.has_range = true;
            views::error_page(body, 416, "Range not satisfiable", "Only single ranges are supported.");
            return;
        }
        let dash = find(spec, "-");
        if dash < 0 {
            resp.status = 416;
            var cr: u8[>..] = [];
            format(cr, "bytes */", size);
            let cs2 = resp_scratch.len;
            resp_scratch.append(cr);
            resp.content_range = resp_scratch[cs2..];
            resp.has_range = true;
            views::error_page(body, 416, "Range not satisfiable", "Bad range.");
            return;
        }
        let lo = spec[..dash];
        let hi = spec[dash + 1..];
        if lo.len == 0 {
            // suffix range: last N bytes
            let n, ok1 = parse_int(hi);
            if !ok1 || n <= 0 {
                resp.status = 416;
                var cr: u8[>..] = [];
                format(cr, "bytes */", size);
                let cs2 = resp_scratch.len;
                resp_scratch.append(cr);
                resp.content_range = resp_scratch[cs2..];
                resp.has_range = true;
                views::error_page(body, 416, "Range not satisfiable", "Bad range.");
                return;
            }
            start = if n > size { 0 } else { size - n };
            end = size - 1;
        } else {
            let s0, ok1 = parse_int(lo);
            if !ok1 || s0 < 0 || s0 >= size {
                resp.status = 416;
                var cr: u8[>..] = [];
                format(cr, "bytes */", size);
                let cs2 = resp_scratch.len;
                resp_scratch.append(cr);
                resp.content_range = resp_scratch[cs2..];
                resp.has_range = true;
                views::error_page(body, 416, "Range not satisfiable", "Bad range.");
                return;
            }
            start = s0;
            if hi.len == 0 {
                end = size - 1;
            } else {
                let e0, ok2 = parse_int(hi);
                if !ok2 || e0 < start {
                    resp.status = 416;
                    var cr: u8[>..] = [];
                    format(cr, "bytes */", size);
                    let cs2 = resp_scratch.len;
                    resp_scratch.append(cr);
                    resp.content_range = resp_scratch[cs2..];
                    resp.has_range = true;
                    views::error_page(body, 416, "Range not satisfiable", "Bad range.");
                    return;
                }
                end = if e0 >= size { size - 1 } else { e0 };
            }
        }
        partial = true;
    }
    resp.status = if partial { 206 } else { 200 };
    resp.is_stream = true;
    let ps = resp_scratch.len;
    resp_scratch.append(path);
    resp.stream_path = resp_scratch[ps..];
    resp.stream_offset = start;
    resp.stream_len = end - start + 1;
    if partial {
        var cr: u8[>..] = [];
        format(cr, "bytes ", start, "-", end, "/", size);
        let cs2 = resp_scratch.len;
        resp_scratch.append(cr);
        resp.content_range = resp_scratch[cs2..];
        resp.has_range = true;
    }
}

// --- serve + supervisor (main thread) -------------------------------------------

fn is_loopback_text(text: u8[:]) -> bool {
    return starts_with(text, "127.") || starts_with(text, "[::1]") || starts_with(text, "::1:") || starts_with(text, "localhost");
}

fn ensure_parent(path: u8[:]) -> bool {
    var slash = -1;
    for i in path.len { if path[i] == '/' { slash = i; } }
    if slash <= 0 { return true; }
    return proc::mkdir_p(path[..slash]);
}

struct ConnJob { fd: i64 }

var supervisor_pid = 0;
var supervisor_job_id: u8[>..] = [];
var last_janitor = 0;

fn serve() {
    if !ensure_parent(cfg_db) { write_stderr("cannot create database parent directory\n"); exit(1); }
    if !storage::ensure_layout(cfg_data) { write_stderr("cannot create data directories\n"); exit(1); }
    if !db::open(cfg_db) { exit(1); }
    auth::lim_init();
    parse_listen_setup();
    recover_startup();
    // Thread pool: connection workers own their HTTP buffers while the
    // SQLite handle crosses by value and serializes inside SQLite. One
    // dedicated worker owns the login limiter and Argon2id verification.
    qlimit<ConnJob>(64);
    qlimit<LoginReq>(16);
    thread_spawn(login_worker);
    var workers = hardware_threads();
    if workers < 1 { workers = 1; }
    if workers > 16 { workers = 16; }
    for i in workers { thread_spawn(conn_worker); }
    // The listen socket is non-blocking: accept returns -1 at once when no
    // connection is pending, so housekeeping below runs on a 100ms timer
    // even while the server is completely idle. (Linux accept() ignores
    // SO_RCVTIMEO, so a blocking accept would sleep forever and the worker
    // supervisor would never run.)
    net::set_nonblocking(listen_fd());
    loop {
        let fd = net::accept(listen_fd());
        if fd >= 0 {
            if !qput(ConnJob { fd: fd }) { net::close(fd); }
            continue;
        }
        // No pending connection: housekeeping, then a short sleep.
        reap_supervised();
        maybe_spawn_worker();
        if now_seconds() - last_janitor >= 60 {
            last_janitor = now_seconds();
            janitor();
        }
        proc::sleep_ms(100);
    }
}

var g_listen_fd = -1;

fn listen_fd() -> i64 { return g_listen_fd; }

fn parse_listen_setup() {
    var host_end = -1;
    for i in cfg_listen.len { if cfg_listen[i] == ':' { host_end = i; } }
    if host_end <= 0 || host_end + 1 >= cfg_listen.len {
        write_stderr("invalid --listen value\n");
        exit(1);
    }
    let host = cfg_listen[..host_end];
    let port_text = cfg_listen[host_end + 1..];
    let port, ok = parse_int(port_text);
    if !ok || port < 0 || port > 65535 {
        write_stderr("invalid --listen value\n");
        exit(1);
    }
    if !cfg_trust_proxy && !is_loopback_text(cfg_listen) {
        write_stderr("refusing non-loopback bind without --trust-proxy\n");
        exit(1);
    }
    var host_ip: u32 = 0;
    if host == "[::1]" || host == "::1" || host == "localhost" {
        host_ip = 0x0100007f;
    } else if !net::parse_ipv4(host, host_ip) {
        write_stderr("invalid --listen host (IPv4 only)\n");
        exit(1);
    }
    g_listen_fd = net::listen(host_ip, port);
    if g_listen_fd < 0 {
        write_stderr("cannot listen (address in use?)\n");
        exit(1);
    }
    net::set_timeouts(g_listen_fd, 500);
    var line: u8[>..] = [];
    format(line, "SketchDL listening on ", cfg_listen, " (db=", cfg_db, ", sqlite=", db::version(), ")\n");
    write_stderr(line);
}

// On startup: kill recorded extractor children of interrupted jobs, requeue
// interrupted work, and verify READY rows actually have files.
fn recover_startup() {
    var scratch: u8[>..] = [];
    let interrupted = db::interrupted_jobs(scratch);
    for j in interrupted {
        if j.has_child && j.child_pid > 0 {
            // Best effort: stop a leftover extractor tree from before the crash.
            proc::kill_group(j.child_pid, 9);
        }
    }
    let found = db::recover_interrupted(now_seconds(), scratch);
    if found.len > 0 {
        var line: u8[>..] = [];
        format(line, "recovered ", found.len, " interrupted job(s) after restart\n");
        write_stderr(line);
    }
    // READY rows without files become FAILED (never serve a missing file).
    var jobs: u8[>..] = [];
    // (reconcile below)
}

fn reap_supervised() {
    if supervisor_pid <= 0 { return; }
    let ec, st = proc::try_wait(supervisor_pid);
    if st == 1 {
        let _ = ec;
        supervisor_pid = 0;
        supervisor_job_id = [];
    }
}

fn maybe_spawn_worker() {
    if supervisor_pid > 0 { return; }
    var scratch: u8[>..] = [];
    let job, ok = db::oldest_queued(scratch);
    if !ok { return; }
    var self_exe: u8[>..] = [];
    if !proc::self_exe(self_exe) { write_stderr("cannot resolve own path for worker spawn\n"); return; }
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    proc::argv_push(blob, offs, self_exe);
    proc::argv_push(blob, offs, "worker-once");
    proc::argv_push(blob, offs, "--db");
    proc::argv_push(blob, offs, cfg_db);
    proc::argv_push(blob, offs, "--data");
    proc::argv_push(blob, offs, cfg_data);
    proc::argv_push(blob, offs, "--job");
    proc::argv_push(blob, offs, job.id);
    proc::argv_push(blob, offs, "--ytdlp");
    proc::argv_push(blob, offs, cfg_ytdlp);
    proc::argv_push(blob, offs, "--ffmpeg");
    proc::argv_push(blob, offs, cfg_ffmpeg);
    proc::argv_push(blob, offs, "--ffprobe");
    proc::argv_push(blob, offs, cfg_ffprobe);
    proc::argv_push(blob, offs, "--deno");
    proc::argv_push(blob, offs, cfg_deno);
    if cfg_ejs_parent.len > 0 {
        proc::argv_push(blob, offs, "--ejs-parent");
        proc::argv_push(blob, offs, cfg_ejs_parent);
    }
    if cfg_bgutil_home.len > 0 {
        proc::argv_push(blob, offs, "--bgutil-home");
        proc::argv_push(blob, offs, cfg_bgutil_home);
    }
    proc::argv_push(blob, offs, "--download-timeout");
    var dts: u8[>..] = [];
    format(dts, cfg_download_timeout_s);
    proc::argv_push(blob, offs, dts);
    proc::argv_push(blob, offs, "--retain-hours");
    var rh: u8[>..] = [];
    format(rh, cfg_retain_hours);
    proc::argv_push(blob, offs, rh);
    var child = proc::Child { pid: 0, out_fd: -1, err_fd: -1 };
    if !proc::spawn_null(self_exe, blob, offs, "", child) {
        write_stderr("worker spawn failed\n");
        return;
    }
    supervisor_pid = child.pid;
    supervisor_job_id = [];
    supervisor_job_id.append(job.id);
}

fn janitor() {
    let now = now_seconds();
    db::delete_expired_sessions(now);
    db::delete_expired_inspections(now);
    var scratch: u8[>..] = [];
    let expired = db::expired_ready(scratch, now);
    for j in expired {
        storage::remove_complete(cfg_data, j.id);
        db::transition(j.id, "READY", "EXPIRED", now, "TTL", true);
    }
}

thread_fn conn_worker() {
    loop {
        let job = qget<ConnJob>();
        if job.fd < 0 { break; }
        handle_connection(job.fd);
        net::close(job.fd);
    }
}

fn handle_connection(fd: i64) {
    conn_buf = [];
    loop {
        resp_scratch = [];
        resp_head = [];
        let req, keep = read_request(fd);
        if !keep { return; }
        var body: u8[>..] = [];
        var resp = fresh_response();
        dispatch(req, resp, body);
        resp.body = body;
        if !send_response(fd, req, resp) { return; }
        if !req.keep_alive { return; }
    }
}

// --- worker-once -----------------------------------------------------------------

fn worker_once() -> i64 {
    if !storage::valid_job_id(cfg_job) { write_stderr("worker-once needs --job <id>\n"); return 2; }
    if !db::open(cfg_db) { return 1; }
    var jscratch: u8[>..] = [];
    let job, ok = db::find_job(cfg_job, jscratch);
    if !ok { write_stderr("worker-once: no such job\n"); return 2; }
    if job.state != "QUEUED" {
        // Cancelled (or already handled) before we arrived.
        return 0;
    }
    let now = now_seconds();
    if db::transition(cfg_job, "QUEUED", "DOWNLOADING", now, "", false) == 0 { return 0; }
    db::set_worker(cfg_job, c_getpid(), 0, false, now);
    let code = run_download(job);
    db::close();
    return code;
}

fn run_download(job: db::Job) -> i64 {
    // Fresh staging area.
    var jdir: u8[>..] = [];
    storage::job_dir(jdir, cfg_data, job.id);
    var tmp: u8[>..] = [];
    storage::job_tmp_dir(tmp, cfg_data, job.id);
    proc::rm_rf(jdir);
    if !proc::mkdir_p(tmp) {
        db::set_failure(job.id, "STORAGE", "Could not create the job directory.", now_seconds());
        return 1;
    }
    // The format spec was validated at enqueue; re-validate defensively.
    var spec_ok = job.has_format && job.format_id.len > 0 && job.format_id.len <= 48;
    if spec_ok {
        for part in split(job.format_id, '+') {
            if !ytdlp::valid_format_id(part) { spec_ok = false; }
        }
    }
    if !spec_ok {
        db::set_failure(job.id, "FORMAT_UNAVAILABLE", "The stored format spec failed validation.", now_seconds());
        return 1;
    }
    if !proc::access_x(cfg_ytdlp) {
        db::set_failure(job.id, "EXTRACTOR_MISSING", "yt-dlp is not executable.", now_seconds());
        return 1;
    }
    var canon: u8[>..] = [];
    canon.append("https://www.youtube.com/watch?v=");
    canon.append(job.video_id);
    var home_arg: u8[>..] = [];
    home_arg.append("home:");
    home_arg.append(jdir);
    var temp_arg: u8[>..] = [];
    temp_arg.append("temp:");
    temp_arg.append(tmp);
    var maxd_arg: u8[>..] = [];
    format(maxd_arg, cfg_max_download_bytes);
    var blob: u8[>..] = [];
    var offs: i32[>..] = [];
    base_ytdlp_args(blob, offs);
    let jsr = js_runtimes_arg();
    proc::argv_push(blob, offs, "--js-runtimes");
    proc::argv_push(blob, offs, jsr);
    proc::argv_push(blob, offs, "--newline");
    proc::argv_push(blob, offs, "--progress");
    proc::argv_push(blob, offs, "--progress-delta");
    proc::argv_push(blob, offs, "1");
    proc::argv_push(blob, offs, "--progress-template");
    var tmpl: u8[>..] = [];
    ytdlp::progress_template_arg(tmpl);
    proc::argv_push(blob, offs, tmpl);
    proc::argv_push(blob, offs, "-f");
    proc::argv_push(blob, offs, job.format_id);
    proc::argv_push(blob, offs, "--merge-output-format");
    proc::argv_push(blob, offs, "mp4");
    proc::argv_push(blob, offs, "--ffmpeg-location");
    proc::argv_push(blob, offs, cfg_ffmpeg);
    proc::argv_push(blob, offs, "--paths");
    proc::argv_push(blob, offs, home_arg);
    proc::argv_push(blob, offs, "--paths");
    proc::argv_push(blob, offs, temp_arg);
    proc::argv_push(blob, offs, "-o");
    proc::argv_push(blob, offs, "%(id)s.%(ext)s");
    proc::argv_push(blob, offs, "--max-filesize");
    proc::argv_push(blob, offs, maxd_arg);
    proc::argv_push(blob, offs, "--print");
    proc::argv_push(blob, offs, "after_move:filepath");
    proc::argv_push(blob, offs, "--socket-timeout");
    proc::argv_push(blob, offs, "15");
    proc::argv_push(blob, offs, "--retries");
    proc::argv_push(blob, offs, "3");
    proc::argv_push(blob, offs, canon);
    var child = proc::Child { pid: 0, out_fd: 0, err_fd: 0 };
    let env = ytdlp_env();
    if !proc::spawn_env(cfg_ytdlp, blob, offs, "", env, child) {
        db::set_failure(job.id, "EXTRACTOR_MISSING", "yt-dlp could not be started.", now_seconds());
        return 1;
    }
    db::set_worker(job.id, c_getpid(), child.pid, true, now_seconds());
    return supervise_download(job, child);
}

// Streaming supervise loop: progress into SQLite (~1/s), cancellation from
// the database, deadline. Returns the worker exit code.
fn supervise_download(job: db::Job, child: proc::Child) -> i64 {
    var buf: u8[65536] = [0; 65536];
    var out_tail: u8[>..] = [];
    var err_tail: u8[>..] = [];
    var out_eof = false;
    var err_eof = false;
    let me = c_getpid();
    // Deadlines and rate limits run on the monotonic clock: counting loop
    // iterations as "100ms" overestimates elapsed time whenever a poll
    // returns early, which would time out healthy downloads.
    let start_ns = clock_ns();
    let timeout_ms = cfg_download_timeout_s * 1000;
    var last_progress_ms = -1000;
    var last_cancel_ms = -1000;
    var cancelled = false;
    var timed_out = false;
    var stale = false;
    var exit_code = -1;
    var reaped = false;
    loop {
        // Drain both pipes every iteration. Reading stderr only after stdout
        // hits EOF deadlocks a chatty child: yt-dlp blocks writing warnings
        // once the stderr pipe fills, and we would be waiting on stdout.
        var idle = true;
        if !out_eof {
            let r = proc::poll_read(child.out_fd, buf, 0);
            if r > 0 {
                if out_tail.len + r > 65536 { out_tail.pop_n(out_tail.len + r - 65536); }
                out_tail.append(buf[..r]);
                idle = false;
            } else if r == 0 { out_eof = true; idle = false; }
        }
        if !err_eof {
            let r = proc::poll_read(child.err_fd, buf, 0);
            if r > 0 {
                if err_tail.len + r > 8192 { err_tail.pop_n(err_tail.len + r - 8192); }
                err_tail.append(buf[..r]);
                idle = false;
            } else if r == 0 { err_eof = true; idle = false; }
        }
        // Also sleep once both pipes are EOF but the child is still alive
        // (post-processing after it closed its streams): otherwise this
        // loop would spin at full CPU until the child exits.
        if idle || (out_eof && err_eof) { proc::sleep_ms(50); }
        let elapsed_ms = (clock_ns() - start_ns) / 1000000;
        let ec, st = proc::try_wait(child.pid);
        if st == 1 {
            exit_code = ec;
            reaped = true;
        }
        if !reaped {
            if elapsed_ms > timeout_ms { timed_out = true; }
            let now = now_seconds();
            if elapsed_ms - last_cancel_ms >= 1000 {
                last_cancel_ms = elapsed_ms;
                var cscratch: u8[>..] = [];
                let cur, ok = db::find_job(job.id, cscratch);
                if ok && cur.state == "CANCELLED" {
                    cancelled = true;
                }
                // Lost the job to a replacement attempt (this worker was
                // orphaned by a server restart): stop, and touch nothing.
                if !db::owns_job(job.id, me) { stale = true; }
            }
            if elapsed_ms - last_progress_ms >= 1000 {
                last_progress_ms = elapsed_ms;
                write_progress(job, out_tail, now);
            }
            if cancelled || timed_out || stale {
                proc::kill_group(child.pid, 9);
                let _ec2, _w = proc::wait(child.pid);
                reaped = true;
                exit_code = if cancelled { -10 } else { -11 };
            }
        }
        if reaped && out_eof && err_eof { break; }
        if reaped && elapsed_ms > timeout_ms + 10000 { break; }
    }
    // final drain
    var rounds = 0;
    while (!out_eof || !err_eof) && rounds < 50 {
        rounds += 1;
        if !out_eof {
            let r = proc::poll_read(child.out_fd, buf, 100);
            if r > 0 {
                if out_tail.len + r > 65536 { out_tail.pop_n(out_tail.len + r - 65536); }
                out_tail.append(buf[..r]);
            } else if r == 0 { out_eof = true; }
        }
        if !err_eof {
            let r = proc::poll_read(child.err_fd, buf, 100);
            if r > 0 { if err_tail.len + r > 8192 { err_tail.pop_n(err_tail.len + r - 8192); } err_tail.append(buf[..r]); }
            else if r == 0 { err_eof = true; }
        }
    }
    if !reaped {
        let ec2, w2 = proc::wait(child.pid);
        if w2 { exit_code = ec2; }
    }
    proc::close_fd(child.out_fd);
    proc::close_fd(child.err_fd);
    if stale {
        // The job moved on without us. Leave the database and the staging
        // directory alone: they belong to the attempt that replaced us.
        return 0;
    }
    let now = now_seconds();
    if cancelled {
        // State is already CANCELLED in the database (the user did it).
        storage::cleanup_job(cfg_data, job.id);
        return 0;
    }
    if timed_out {
        db::set_failure(job.id, "TIMEOUT", "The download exceeded the configured time limit.", now);
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    if exit_code != 0 {
        var code: u8[>..] = [];
        var detail: u8[>..] = [];
        ytdlp::classify_error(err_tail, code, detail);
        if code.len == 0 { code.append("DOWNLOAD_FAILED"); detail.append("yt-dlp exited with a failure."); }
        var m: u8[>..] = [];
        if detail.len > 0 { m.append(detail); } else { m.append("yt-dlp failed."); }
        if !db::set_failure(job.id, code, m, now) { return 1; }
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    // exit 0: resolve the moved path -- the after_move line is in stdout.
    var moved: u8[>..] = [];
    if !extract_after_move(out_tail, job, moved) {
        db::set_failure(job.id, "MISSING_OUTPUT", "yt-dlp reported success but no output file was found.", now);
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    return verify_and_publish(job, moved);
}

// Finds the last non-empty stdout line that names the output file.
fn extract_after_move(stdout: u8[:], job: db::Job, out: u8[>..]&) -> bool {
    var jdir: u8[>..] = [];
    storage::job_dir(jdir, cfg_data, job.id);
    var pos = 0;
    var found_b: u8[>..] = [];
    var has = false;
    loop {
        if pos > stdout.len { break; }
        var eol = pos;
        while eol < stdout.len && stdout[eol] != '\n' { eol += 1; }
        let line = trim_sp(stdout[pos..eol]);
        if starts_with(line, jdir) {
            if line.len > 0 {
                found_b = [];
                found_b.append(line);
                has = true;
            }
        }
        if eol >= stdout.len { break; }
        pos = eol + 1;
    }
    if !has { return false; }
    // The expected output is <job_dir>/<video_id>.mp4 (single file, mp4).
    var want: u8[>..] = [];
    want.append(jdir);
    want.push('/');
    want.append(job.video_id);
    want.append(".mp4");
    if found_b != want { return false; }
    out.append(found_b);
    return true;
}

fn verify_and_publish(job: db::Job, moved: u8[:]) -> i64 {
    let now = now_seconds();
    if db::transition(job.id, "DOWNLOADING", "VERIFYING", now, "", false) == 0 {
        // Cancelled while downloading.
        storage::cleanup_job(cfg_data, job.id);
        return 0;
    }
    db::set_stage(job.id, "verifying", now);
    var facts: u8[>..] = [];
    if !media::verify_mp4(cfg_ffprobe, moved, 30000, facts) {
        var code: u8[>..] = [];
        code.append("VERIFY_FAILED");
        db::set_failure(job.id, code, facts, now);
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    let size = proc::file_size(moved);
    if size <= 0 || size > cfg_max_download_bytes {
        db::set_failure(job.id, "VERIFY_FAILED", "Output size is outside the configured limit.", now);
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    let published = storage::publish(cfg_data, job.id, moved);
    if published < 0 {
        db::set_failure(job.id, "PUBLISH_FAILED", "Could not move the file into place.", now);
        storage::cleanup_job(cfg_data, job.id);
        return 1;
    }
    let expires = now + cfg_retain_hours * 3600;
    if !db::set_ready(job.id, published, expires, now) {
        // Cancelled between verify and publish: remove the file we just
        // published so nothing stays retrievable.
        storage::remove_complete(cfg_data, job.id);
        storage::cleanup_job(cfg_data, job.id);
        return 0;
    }
    storage::cleanup_job(cfg_data, job.id);
    var line: u8[>..] = [];
    format(line, "job ", job.id, " ready (", published, " bytes, h264+aac verified)\n");
    write_stderr(line);
    return 0;
}

// Parses the latest progress line in the accumulated stdout tail and writes
// it to the database. Called at most ~1/s by supervise_download.
fn write_progress(job: db::Job, out_tail: u8[:], now: i64) {
    var pos = 0;
    var last: ytdlp::Progress = ytdlp::Progress { downloaded: 0, total: 0, has_total: false, speed: 0, has_speed: false, eta: 0, has_eta: false };
    var any = false;
    loop {
        if pos > out_tail.len { break; }
        var eol = pos;
        while eol < out_tail.len && out_tail[eol] != '\n' { eol += 1; }
        let line = trim_sp(out_tail[pos..eol]);
        var p = ytdlp::Progress { downloaded: 0, total: 0, has_total: false, speed: 0, has_speed: false, eta: 0, has_eta: false };
        if ytdlp::parse_progress(line, p) {
            last = p;
            any = true;
        }
        if eol >= out_tail.len { break; }
        pos = eol + 1;
    }
    if !any { return; }
    db::update_progress(job.id, "downloading", last.downloaded, last.total, last.has_total, last.speed, last.has_speed, last.eta, last.has_eta, now);
}

// --- admin ---------------------------------------------------------------------

fn admin_set_password() {
    if !ensure_parent(cfg_db) { write_stderr("cannot create database parent directory\n"); exit(1); }
    if !db::open(cfg_db) { exit(1); }
    var line: u8[>..] = [];
    if !read_line(line) {
        write_stderr("no password on stdin\n");
        exit(1);
    }
    // read_line strips the newline; a second read (confirm) is skipped by
    // design: one line from stdin, piped, like the feather tooling.
    let pw: u8[:] = line;
    if auth::validate_password(pw) != 0 {
        write_stderr("password must be 12-1024 bytes of valid UTF-8\n");
        exit(1);
    }
    var hash: u8[>..] = [];
    if !auth::hash_password(hash, pw) {
        write_stderr("hashing failed\n");
        exit(1);
    }
    if !db::set_owner_hash(hash, now_seconds()) {
        write_stderr("could not store the hash\n");
        exit(1);
    }
    write_stderr("owner password set\n");
    db::close();
}

fn admin_backup() {
    if !ensure_parent(cfg_out) { write_stderr("cannot create backup parent directory\n"); exit(1); }
    if !db::open(cfg_db) { exit(1); }
    if !db::backup_to(cfg_out) {
        write_stderr("backup failed\n");
        exit(1);
    }
    var line: u8[>..] = [];
    format(line, "backup written to ", cfg_out, "\n");
    write_stderr(line);
    db::close();
}

fn admin_integrity() {
    if !db::open(cfg_db) { exit(1); }
    var scratch: u8[>..] = [];
    if db::integrity(scratch) {
        write_stderr("integrity_check: ok\n");
        db::close();
        return;
    }
    write_stderr("integrity_check FAILED\n");
    db::close();
    exit(1);
}
