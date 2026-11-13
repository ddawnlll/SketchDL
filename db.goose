// SQLite persistence layer over the vendored amalgamation, bound directly
// from Goose. One connection opened with SQLITE_OPEN_FULLMUTEX, so the
// connection-worker pool serializes inside SQLite. Video bytes never touch
// SQLite; only metadata does.
namespace db;

import std;
import os;
import ffi;
import util;
import proc;

extern fn sqlite3_open_v2(filename: const u8&, db: u64&, flags: i32, vfs: u64) -> i32;
extern fn sqlite3_close(db: u64) -> i32;
extern fn sqlite3_exec(db: u64, sql: const u8&, cb: u64, arg: u64, msg: u64&) -> i32;
extern fn sqlite3_prepare_v2(db: u64, sql: const u8&, nbyte: i32, stmt: u64&, tail: u64&) -> i32;
extern fn sqlite3_step(stmt: u64) -> i32;
extern fn sqlite3_finalize(stmt: u64) -> i32;
extern fn sqlite3_bind_text(stmt: u64, idx: i32, text: const u8&, n: i32, dtor: u64) -> i32;
extern fn sqlite3_bind_blob(stmt: u64, idx: i32, data: const u8&, n: i32, dtor: u64) -> i32;
extern fn sqlite3_bind_int64(stmt: u64, idx: i32, value: i64) -> i32;
extern fn sqlite3_column_int64(stmt: u64, col: i32) -> i64;
extern fn sqlite3_column_type(stmt: u64, col: i32) -> i32;
extern fn sqlite3_column_text(stmt: u64, col: i32) -> u64;
extern fn sqlite3_column_bytes(stmt: u64, col: i32) -> i32;
extern fn sqlite3_changes(db: u64) -> i32;
extern fn sqlite3_last_insert_rowid(db: u64) -> i64;
extern fn sqlite3_libversion() -> u64;
extern fn sqlite3_backup_init(dest: u64, dest_name: const u8&, src: u64, src_name: const u8&) -> u64;
extern fn sqlite3_backup_step(backup: u64, pages: i32) -> i32;
extern fn sqlite3_backup_finish(backup: u64) -> i32;
extern fn sqlite3_busy_timeout(db: u64, ms: i32) -> i32;
extern fn sqlite3_extended_result_codes(db: u64, onoff: i32) -> i32;
extern fn c_getpid() -> i64 = "getpid";

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL = 5;
const SQLITE_TRANSIENT: u64 = 18446744073709551615;
const OPEN_RW: i32 = 0x2;
const OPEN_CREATE: i32 = 0x4;
const OPEN_FULLMUTEX: i32 = 0x10000;

var handle: u64 = 0;

// Per-call connections. Threads never share mutable memory in Goose: each
// thread program owns its globals (see goose_spec.md §11.2), so `handle`
// and `conn_depth` below are per-thread state. Every public function
// opens its own connection, uses it, and closes it before returning.
// Nested calls share the outer connection via the depth counter.
//
// These functions must NOT rely on `defer` for cleanup: the Goose
// compiler's inliner has been observed (at -O1/-O2) to emit deferred
// bodies on only one side of a return-value branch when a function is
// inlined and its result is consumed in a branch, leaking statements
// and connections (reproduced with a minimal program; -O0 is correct).
// Until that is fixed upstream, every exit path below runs its cleanup
// explicitly. Do not reintroduce `defer` here.
var g_db_path: u8[>..] = [];
var conn_depth = 0;

fn open_req() -> bool {
    if conn_depth == 0 {
        // sqlite3_open_v2 can return SQLITE_BUSY when other connections
        // (worker processes, or a concurrent request) hold the WAL index
        // lock; the busy timeout only applies after a successful open.
        // Retry a few times so a transient lock never surfaces as a 401.
        var ok = false;
        for attempt in 5 {
            if try_open_once() { ok = true; break; }
            if attempt < 4 { proc::sleep_ms(20); }
        }
        if !ok { return false; }
    }
    conn_depth += 1;
    return true;
}

fn try_open_once() -> bool {
    var pathb: u8[>..] = [];
    pathb.append(g_db_path);
    pathb.push(0);
    var h: u64 = 0;
    let flags = OPEN_RW | OPEN_CREATE | OPEN_FULLMUTEX;
    if sqlite3_open_v2(pathb[0], h, flags, 0) != SQLITE_OK {
        if h != 0 { sqlite3_close(h); }
        return false;
    }
    handle = h;
    sqlite3_extended_result_codes(handle, 1);
    sqlite3_busy_timeout(handle, 5000);
    if !exec_raw("PRAGMA synchronous=FULL;") { sqlite3_close(handle); handle = 0; return false; }
    if !exec_raw("PRAGMA foreign_keys=ON;") { sqlite3_close(handle); handle = 0; return false; }
    if !exec_raw("PRAGMA trusted_schema=OFF;") { sqlite3_close(handle); handle = 0; return false; }
    if !exec_raw("PRAGMA temp_store=MEMORY;") { sqlite3_close(handle); handle = 0; return false; }
    if !exec_raw("PRAGMA cache_size=-512;") { sqlite3_close(handle); handle = 0; return false; }
    return true;
}

fn close_req() {
    if conn_depth <= 0 { return; }
    conn_depth -= 1;
    if conn_depth == 0 && handle != 0 {
        sqlite3_close(handle);
        handle = 0;
    }
}

var zero_byte: u8[1] = [0];

fn bind_text(stmt: u64, idx: i32, text: u8[:]) {
    if text.len == 0 {
        sqlite3_bind_text(stmt, idx, zero_byte[0], 0, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_text(stmt, idx, text[0], text.len as i32, SQLITE_TRANSIENT);
    }
}

fn bind_blob(stmt: u64, idx: i32, data: u8[:]) {
    if data.len == 0 {
        sqlite3_bind_blob(stmt, idx, zero_byte[0], 0, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_blob(stmt, idx, data[0], data.len as i32, SQLITE_TRANSIENT);
    }
}

fn version() -> u8[>..] { ffi::cstr(sqlite3_libversion()) }

fn exec_raw(sql: u8[:]) -> bool {
    if sql.len == 0 { return true; }
    var sqlb: u8[>..] = [];
    sqlb.append(sql);
    sqlb.push(0);
    var msg: u64 = 0;
    let rc = sqlite3_exec(handle, sqlb[0], 0, 0, msg);
    if rc != SQLITE_OK {
        var line: u8[>..] = [];
        format(line, "sqlite exec failed rc=", rc, " sql=", sql, " msg=");
        ffi::cstr(msg, line);
        line.append("\n");
        write_stderr(line);
        return false;
    }
    return true;
}

struct Stmt { h: u64, ok: bool }

fn prepare(sql: u8[:]) -> Stmt {
    var sqlb: u8[>..] = [];
    sqlb.append(sql);
    sqlb.push(0);
    var h: u64 = 0;
    var tail: u64 = 0;
    let rc = sqlite3_prepare_v2(handle, sqlb[0], -1, h, tail);
    if rc != SQLITE_OK {
        var line: u8[>..] = [];
        format(line, "sqlite prepare failed rc=", rc, " sql=", sql, "\n");
        write_stderr(line);
        return Stmt { h: 0, ok: false };
    }
    return Stmt { h: h, ok: true };
}

fn release(stmt: Stmt) {
    if stmt.ok { sqlite3_finalize(stmt.h); }
}

// Single-row step helper: true if a row is available.
fn step_row(stmt: Stmt) -> bool {
    return sqlite3_step(stmt.h) == SQLITE_ROW;
}

fn open(path: u8[:]) -> bool {
    g_db_path = [];
    g_db_path.append(path);
    if !open_req() {
        var line: u8[>..] = [];
        format(line, "cannot open database ", path, "\n");
        write_stderr(line);
        return false;
    }
    // Rollback journal (DELETE), deliberately not WAL. This app opens a
    // fresh connection per call; with WAL, sqlite3_close on a short-lived
    // connection can delete and recreate the -shm/-wal files mid-flight,
    // leaving other connections mapped to an unlinked wal-index that no
    // longer sees new frames (per-call readers then miss committed rows).
    // Rollback journaling has no such files and no such failure mode.
    let ok = exec_raw("PRAGMA journal_mode=DELETE;") && migrate();
    close_req();
    return ok;
}

fn close() {
    // Connections are opened and closed per call (see open_req), so there
    // is nothing to close here. Kept for existing callers. Note that no
    // wal_checkpoint happens on close: a short-lived process truncating
    // the WAL under other connections can strand their WAL state.
}

fn migrate() -> bool {
    if !exec_raw("CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);") { return false; }
    var current = schema_version();
    if current < 0 {
        // Fresh database: seed the version row, then re-read. A current
        // database skips this write entirely (no write lock on open).
        if !exec_raw("INSERT INTO schema_meta(version) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);") { return false; }
        current = schema_version();
        if current < 0 { return false; }
    }
    if current > 1 {
        write_stderr("database schema version too new\n");
        return false;
    }
    if current == 0 {
        if !exec_raw("BEGIN IMMEDIATE;") { return false; }
        if !exec_raw(embed_file("migrations/0001_init.sql")) { exec_raw("ROLLBACK;"); return false; }
        if !exec_raw("UPDATE schema_meta SET version = 1;") { exec_raw("ROLLBACK;"); return false; }
        if !exec_raw("COMMIT;") { return false; }
    }
    return true;
}

fn schema_version() -> i64 {
    let stmt = prepare("SELECT version FROM schema_meta LIMIT 1");
    if !stmt.ok { return -1; }
    var r = -1;
    if sqlite3_step(stmt.h) == SQLITE_ROW { r = sqlite3_column_int64(stmt.h, 0); }
    release(stmt);
    return r;
}

// --- owner ----------------------------------------------------------------

fn has_owner() -> bool {
    if !open_req() { return false; }
    let stmt = prepare("SELECT COUNT(*) FROM owner");
    var r = false;
    if stmt.ok {
        if sqlite3_step(stmt.h) == SQLITE_ROW { r = sqlite3_column_int64(stmt.h, 0) > 0; }
        release(stmt);
    }
    close_req();
    return r;
}

fn owner_hash(scratch: u8[>..]&) -> u8[:], bool {
    if !open_req() { return "", false; }
    let stmt = prepare("SELECT password_hash FROM owner WHERE id = 1");
    if !stmt.ok { close_req(); return "", false; }
    if sqlite3_step(stmt.h) != SQLITE_ROW { release(stmt); close_req(); return "", false; }
    let start = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 0), scratch);
    let r = scratch[start..];
    release(stmt);
    close_req();
    return r, true;
}

fn set_owner_hash(hash: u8[:], now: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("INSERT INTO owner(id, password_hash, created_at) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET password_hash = excluded.password_hash");
    var r = false;
    if stmt.ok {
        bind_text(stmt.h, 1, hash);
        sqlite3_bind_int64(stmt.h, 2, now);
        r = sqlite3_step(stmt.h) == SQLITE_DONE;
        release(stmt);
    }
    close_req();
    return r;
}

// --- sessions --------------------------------------------------------------

fn create_session(token_hash: u8[:], csrf: u8[:], now: i64, expires: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("INSERT INTO sessions(token_hash, owner_id, csrf_token, issued_at, last_used_at, expires_at) VALUES(?, 1, ?, ?, ?, ?)");
    var r = false;
    if stmt.ok {
        bind_text(stmt.h, 1, token_hash);
        bind_text(stmt.h, 2, csrf);
        sqlite3_bind_int64(stmt.h, 3, now);
        sqlite3_bind_int64(stmt.h, 4, now);
        sqlite3_bind_int64(stmt.h, 5, expires);
        r = sqlite3_step(stmt.h) == SQLITE_DONE;
        release(stmt);
    }
    close_req();
    return r;
}

// Returns the CSRF secret for a live session, or false if unknown/expired.
fn find_session(token_hash: u8[:], now: i64, scratch: u8[>..]&) -> u8[:], bool {
    if !open_req() { return "", false; }
    let stmt = prepare("SELECT csrf_token FROM sessions WHERE token_hash = ? AND revoked = 0 AND expires_at > ?");
    if !stmt.ok { close_req(); return "", false; }
    bind_text(stmt.h, 1, token_hash);
    sqlite3_bind_int64(stmt.h, 2, now);
    if sqlite3_step(stmt.h) != SQLITE_ROW { release(stmt); close_req(); return "", false; }
    let start = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 0), scratch);
    let r = scratch[start..];
    release(stmt);
    close_req();
    return r, true;
}

fn touch_session(token_hash: u8[:], now: i64) {
    if !open_req() { return; }
    let stmt = prepare("UPDATE sessions SET last_used_at = ? WHERE token_hash = ?");
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        bind_text(stmt.h, 2, token_hash);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

fn revoke_session(token_hash: u8[:]) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("UPDATE sessions SET revoked = 1 WHERE token_hash = ?");
    var r = false;
    if stmt.ok {
        bind_text(stmt.h, 1, token_hash);
        r = sqlite3_step(stmt.h) == SQLITE_DONE;
        release(stmt);
    }
    close_req();
    return r;
}

fn delete_expired_sessions(now: i64) {
    if !open_req() { return; }
    let stmt = prepare("DELETE FROM sessions WHERE expires_at <= ?");
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

// --- inspections -------------------------------------------------------------

fn store_inspection(token_hash: u8[:], video_id: u8[:], title: u8[:], duration: i64, has_duration: bool, formats_json: u8[:], expires: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("INSERT OR REPLACE INTO inspections(token_hash, owner_id, video_id, title, duration, formats_json, expires_at) VALUES(?, 1, ?, ?, ?, ?, ?)");
    var r = false;
    if stmt.ok {
        bind_text(stmt.h, 1, token_hash);
        bind_text(stmt.h, 2, video_id);
        bind_text(stmt.h, 3, title);
        if has_duration { sqlite3_bind_int64(stmt.h, 4, duration); }
        bind_text(stmt.h, 5, formats_json);
        sqlite3_bind_int64(stmt.h, 6, expires);
        r = sqlite3_step(stmt.h) == SQLITE_DONE;
        release(stmt);
    }
    close_req();
    return r;
}

struct Inspection {
    video_id: const u8[:],
    title: const u8[:],
    duration: i64,
    has_duration: bool,
    formats_json: const u8[:],
}

fn find_inspection(token_hash: u8[:], now: i64, scratch: u8[>..]&) -> Inspection, bool {
    if !open_req() { return Inspection { video_id: "", title: "", duration: 0, has_duration: false, formats_json: "" }, false; }
    var out = Inspection { video_id: "", title: "", duration: 0, has_duration: false, formats_json: "" };
    var ok = false;
    let stmt = prepare("SELECT video_id, title, duration, formats_json FROM inspections WHERE token_hash = ? AND expires_at > ?");
    if stmt.ok {
        bind_text(stmt.h, 1, token_hash);
        sqlite3_bind_int64(stmt.h, 2, now);
        if sqlite3_step(stmt.h) == SQLITE_ROW {
            var s = scratch.len;
            ffi::cstr(sqlite3_column_text(stmt.h, 0), scratch);
            out.video_id = scratch[s..];
            s = scratch.len;
            ffi::cstr(sqlite3_column_text(stmt.h, 1), scratch);
            out.title = scratch[s..];
            if sqlite3_column_type(stmt.h, 2) == SQLITE_NULL { out.has_duration = false; }
            else { out.has_duration = true; out.duration = sqlite3_column_int64(stmt.h, 2); }
            s = scratch.len;
            ffi::cstr(sqlite3_column_text(stmt.h, 3), scratch);
            out.formats_json = scratch[s..];
            ok = true;
        }
        release(stmt);
    }
    close_req();
    return out, ok;
}

fn delete_inspection(token_hash: u8[:]) {
    if !open_req() { return; }
    let stmt = prepare("DELETE FROM inspections WHERE token_hash = ?");
    if stmt.ok {
        bind_text(stmt.h, 1, token_hash);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

fn delete_expired_inspections(now: i64) {
    if !open_req() { return; }
    let stmt = prepare("DELETE FROM inspections WHERE expires_at <= ?");
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

// --- jobs -------------------------------------------------------------------

struct Job {
    id: const u8[:],
    video_id: const u8[:],
    title: const u8[:],
    has_title: bool,
    preset: const u8[:],
    format_id: const u8[:],
    has_format: bool,
    state: const u8[:],
    stage: const u8[:],
    has_stage: bool,
    downloaded_bytes: i64,
    total_bytes: i64,
    has_total: bool,
    speed_bps: i64,
    has_speed: bool,
    eta_seconds: i64,
    has_eta: bool,
    output_bytes: i64,
    has_output: bool,
    worker_pid: i64,
    has_worker: bool,
    child_pid: i64,
    has_child: bool,
    error_code: const u8[:],
    has_error: bool,
    error_detail: const u8[:],
    has_detail: bool,
    retry_count: i64,
    created_at: i64,
    updated_at: i64,
    expires_at: i64,
    has_expires: bool,
    version: i64,
}

fn empty_job() -> Job {
    return Job { id: "", video_id: "", title: "", has_title: false, preset: "", format_id: "", has_format: false,
        state: "", stage: "", has_stage: false, downloaded_bytes: 0, total_bytes: 0, has_total: false,
        speed_bps: 0, has_speed: false, eta_seconds: 0, has_eta: false, output_bytes: 0, has_output: false,
        worker_pid: 0, has_worker: false, child_pid: 0, has_child: false, error_code: "", has_error: false,
        error_detail: "", has_detail: false, retry_count: 0, created_at: 0, updated_at: 0,
        expires_at: 0, has_expires: false, version: 0 };
}

const JOB_COLS = "id, video_id, title, preset, format_id, state, stage, downloaded_bytes, total_bytes, speed_bps, eta_seconds, output_bytes, worker_pid, child_pid, error_code, error_detail, retry_count, created_at, updated_at, expires_at, version";

fn read_job_row(stmt: Stmt, scratch: u8[>..]&) -> Job {
    var j = empty_job();
    var s = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 0), scratch);
    j.id = scratch[s..];
    s = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 1), scratch);
    j.video_id = scratch[s..];
    if sqlite3_column_type(stmt.h, 2) != SQLITE_NULL {
        s = scratch.len;
        ffi::cstr(sqlite3_column_text(stmt.h, 2), scratch);
        j.title = scratch[s..];
        j.has_title = true;
    }
    s = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 3), scratch);
    j.preset = scratch[s..];
    if sqlite3_column_type(stmt.h, 4) != SQLITE_NULL {
        s = scratch.len;
        ffi::cstr(sqlite3_column_text(stmt.h, 4), scratch);
        j.format_id = scratch[s..];
        j.has_format = true;
    }
    s = scratch.len;
    ffi::cstr(sqlite3_column_text(stmt.h, 5), scratch);
    j.state = scratch[s..];
    if sqlite3_column_type(stmt.h, 6) != SQLITE_NULL {
        s = scratch.len;
        ffi::cstr(sqlite3_column_text(stmt.h, 6), scratch);
        j.stage = scratch[s..];
        j.has_stage = true;
    }
    j.downloaded_bytes = sqlite3_column_int64(stmt.h, 7);
    if sqlite3_column_type(stmt.h, 8) != SQLITE_NULL { j.total_bytes = sqlite3_column_int64(stmt.h, 8); j.has_total = true; }
    if sqlite3_column_type(stmt.h, 9) != SQLITE_NULL { j.speed_bps = sqlite3_column_int64(stmt.h, 9); j.has_speed = true; }
    if sqlite3_column_type(stmt.h, 10) != SQLITE_NULL { j.eta_seconds = sqlite3_column_int64(stmt.h, 10); j.has_eta = true; }
    if sqlite3_column_type(stmt.h, 11) != SQLITE_NULL { j.output_bytes = sqlite3_column_int64(stmt.h, 11); j.has_output = true; }
    if sqlite3_column_type(stmt.h, 12) != SQLITE_NULL { j.worker_pid = sqlite3_column_int64(stmt.h, 12); j.has_worker = true; }
    if sqlite3_column_type(stmt.h, 13) != SQLITE_NULL { j.child_pid = sqlite3_column_int64(stmt.h, 13); j.has_child = true; }
    if sqlite3_column_type(stmt.h, 14) != SQLITE_NULL {
        s = scratch.len;
        ffi::cstr(sqlite3_column_text(stmt.h, 14), scratch);
        j.error_code = scratch[s..];
        j.has_error = true;
    }
    if sqlite3_column_type(stmt.h, 15) != SQLITE_NULL {
        s = scratch.len;
        ffi::cstr(sqlite3_column_text(stmt.h, 15), scratch);
        j.error_detail = scratch[s..];
        j.has_detail = true;
    }
    j.retry_count = sqlite3_column_int64(stmt.h, 16);
    j.created_at = sqlite3_column_int64(stmt.h, 17);
    j.updated_at = sqlite3_column_int64(stmt.h, 18);
    if sqlite3_column_type(stmt.h, 19) != SQLITE_NULL { j.expires_at = sqlite3_column_int64(stmt.h, 19); j.has_expires = true; }
    j.version = sqlite3_column_int64(stmt.h, 20);
    return j;
}

fn create_job(id: u8[:], video_id: u8[:], title: u8[:], preset: u8[:], format_id: u8[:], now: i64) -> bool {
    if !open_req() { return false; }
    if !exec_raw("BEGIN IMMEDIATE;") { close_req(); return false; }
    let stmt = prepare("INSERT INTO jobs(id, owner_id, video_id, title, preset, format_id, state, created_at, updated_at) VALUES(?, 1, ?, ?, ?, ?, 'QUEUED', ?, ?)");
    if !stmt.ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    bind_text(stmt.h, 1, id);
    bind_text(stmt.h, 2, video_id);
    bind_text(stmt.h, 3, title);
    bind_text(stmt.h, 4, preset);
    bind_text(stmt.h, 5, format_id);
    sqlite3_bind_int64(stmt.h, 6, now);
    sqlite3_bind_int64(stmt.h, 7, now);
    let ok = sqlite3_step(stmt.h) == SQLITE_DONE;
    release(stmt);
    if !ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    let estmt = prepare("INSERT INTO job_events(job_id, at, from_state, to_state, code) VALUES(?, ?, NULL, 'QUEUED', NULL)");
    if !estmt.ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    bind_text(estmt.h, 1, id);
    sqlite3_bind_int64(estmt.h, 2, now);
    let eok = sqlite3_step(estmt.h) == SQLITE_DONE;
    release(estmt);
    if !eok { exec_raw("ROLLBACK;"); close_req(); return false; }
    if !exec_raw("COMMIT;") { exec_raw("ROLLBACK;"); close_req(); return false; }
    close_req();
    return true;
}

fn find_job(id: u8[:], scratch: u8[>..]&) -> Job, bool {
    if !open_req() { return empty_job(), false; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    sql.append(JOB_COLS);
    sql.append(" FROM jobs WHERE id = ?");
    var r = empty_job();
    var ok = false;
    let stmt = prepare(sql);
    if stmt.ok {
        bind_text(stmt.h, 1, id);
        if sqlite3_step(stmt.h) == SQLITE_ROW { r = read_job_row(stmt, scratch); ok = true; }
        release(stmt);
    }
    close_req();
    return r, ok;
}

fn list_jobs(limit: i64, scratch: u8[>..]&) -> Job[>..] {
    if !open_req() { var _none: Job[>..] = []; return _none; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    sql.append(JOB_COLS);
    sql.append(" FROM jobs ORDER BY created_at DESC, id DESC LIMIT ?");
    var out: Job[>..] = [];
    let stmt = prepare(sql);
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, limit);
        while sqlite3_step(stmt.h) == SQLITE_ROW {
            out.push(read_job_row(stmt, scratch));
        }
        release(stmt);
    }
    close_req();
    return out;
}

// Conditional state transition: only applies when the job is in from_state.
// Returns the number of rows changed (0 or 1) plus whether the job exists.
fn transition(id: u8[:], from_state: u8[:], to_state: u8[:], now: i64, code: u8[:], has_code: bool) -> i64 {
    if !open_req() { return 0; }
    if !exec_raw("BEGIN IMMEDIATE;") { close_req(); return 0; }
    let stmt = prepare("UPDATE jobs SET state = ?, updated_at = ?, version = version + 1 WHERE id = ? AND state = ?");
    if !stmt.ok { exec_raw("ROLLBACK;"); close_req(); return 0; }
    bind_text(stmt.h, 1, to_state);
    sqlite3_bind_int64(stmt.h, 2, now);
    bind_text(stmt.h, 3, id);
    bind_text(stmt.h, 4, from_state);
    let ok = sqlite3_step(stmt.h) == SQLITE_DONE && sqlite3_changes(handle) > 0;
    release(stmt);
    if !ok { exec_raw("ROLLBACK;"); close_req(); return 0; }
    let estmt = prepare("INSERT INTO job_events(job_id, at, from_state, to_state, code) VALUES(?, ?, ?, ?, ?)");
    if !estmt.ok { exec_raw("ROLLBACK;"); close_req(); return 0; }
    bind_text(estmt.h, 1, id);
    sqlite3_bind_int64(estmt.h, 2, now);
    bind_text(estmt.h, 3, from_state);
    bind_text(estmt.h, 4, to_state);
    if has_code { bind_text(estmt.h, 5, code); }
    let eok = sqlite3_step(estmt.h) == SQLITE_DONE;
    release(estmt);
    if !eok { exec_raw("ROLLBACK;"); close_req(); return 0; }
    if !exec_raw("COMMIT;") { exec_raw("ROLLBACK;"); close_req(); return 0; }
    close_req();
    return 1;
}

// Progress update (rate-limited by the caller). Fenced on worker ownership so
// an orphaned worker cannot overwrite the live attempt's numbers.
fn update_progress(id: u8[:], stage: u8[:], downloaded: i64, total: i64, has_total: bool, speed: i64, has_speed: bool, eta: i64, has_eta: bool, now: i64) {
    if !open_req() { return; }
    let stmt = prepare("UPDATE jobs SET stage = ?, downloaded_bytes = ?, total_bytes = ?, speed_bps = ?, eta_seconds = ?, updated_at = ?, version = version + 1 WHERE id = ? AND worker_pid = ?");
    if stmt.ok {
        bind_text(stmt.h, 1, stage);
        sqlite3_bind_int64(stmt.h, 2, downloaded);
        if has_total { sqlite3_bind_int64(stmt.h, 3, total); }
        if has_speed { sqlite3_bind_int64(stmt.h, 4, speed); }
        if has_eta { sqlite3_bind_int64(stmt.h, 5, eta); }
        sqlite3_bind_int64(stmt.h, 6, now);
        bind_text(stmt.h, 7, id);
        sqlite3_bind_int64(stmt.h, 8, c_getpid());
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

fn set_stage(id: u8[:], stage: u8[:], now: i64) {
    if !open_req() { return; }
    let stmt = prepare("UPDATE jobs SET stage = ?, updated_at = ? WHERE id = ?");
    if stmt.ok {
        bind_text(stmt.h, 1, stage);
        sqlite3_bind_int64(stmt.h, 2, now);
        bind_text(stmt.h, 3, id);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

// Records the worker that owns this attempt. The value doubles as an
// ownership fence: a worker that outlived a SIGKILLed server keeps running
// (it is setsid-detached by design), and without a fence it would happily
// write its stale progress and a terminal FAILED over the fresh attempt the
// restarted server just spawned for the same job.
fn set_worker(id: u8[:], worker_pid: i64, child_pid: i64, has_child: bool, now: i64) {
    if !open_req() { return; }
    let stmt = prepare("UPDATE jobs SET worker_pid = ?, child_pid = ?, updated_at = ?, version = version + 1 WHERE id = ? AND state = 'DOWNLOADING'");
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, worker_pid);
        if has_child { sqlite3_bind_int64(stmt.h, 2, child_pid); }
        sqlite3_bind_int64(stmt.h, 3, now);
        bind_text(stmt.h, 4, id);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

// True when `worker_pid` is still the worker recorded for this job, i.e. this
// process owns the current attempt. Every write a worker makes after it has
// claimed a job goes through this fence.
fn owns_job(id: u8[:], worker_pid: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("SELECT 1 FROM jobs WHERE id = ? AND worker_pid = ? AND state IN ('DOWNLOADING','VERIFYING')");
    var ok = false;
    if stmt.ok {
        bind_text(stmt.h, 1, id);
        sqlite3_bind_int64(stmt.h, 2, worker_pid);
        ok = sqlite3_step(stmt.h) == SQLITE_ROW;
        release(stmt);
    }
    close_req();
    return ok;
}

// Marks an active job FAILED. Returns false when the job already left its
// active state (e.g. it was cancelled), or when another worker owns the
// attempt now: the caller must not overwrite either.
fn set_failure(id: u8[:], code: u8[:], detail: u8[:], now: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("UPDATE jobs SET state = 'FAILED', error_code = ?, error_detail = ?, updated_at = ?, version = version + 1 WHERE id = ? AND state IN ('DOWNLOADING','VERIFYING') AND worker_pid = ?");
    var ok = false;
    if stmt.ok {
        bind_text(stmt.h, 1, code);
        bind_text(stmt.h, 2, detail);
        sqlite3_bind_int64(stmt.h, 3, now);
        bind_text(stmt.h, 4, id);
        sqlite3_bind_int64(stmt.h, 5, c_getpid());
        ok = sqlite3_step(stmt.h) == SQLITE_DONE && sqlite3_changes(handle) > 0;
        release(stmt);
    }
    if ok {
        let estmt = prepare("INSERT INTO job_events(job_id, at, from_state, to_state, code) VALUES(?, ?, NULL, 'FAILED', ?)");
        if estmt.ok {
            bind_text(estmt.h, 1, id);
            sqlite3_bind_int64(estmt.h, 2, now);
            bind_text(estmt.h, 3, code);
            ok = sqlite3_step(estmt.h) == SQLITE_DONE;
            release(estmt);
        } else { ok = false; }
    }
    close_req();
    return ok;
}

fn set_ready(id: u8[:], output_bytes: i64, expires: i64, now: i64) -> bool {
    if !open_req() { return false; }
    if !exec_raw("BEGIN IMMEDIATE;") { close_req(); return false; }
    let stmt = prepare("UPDATE jobs SET state = 'READY', output_bytes = ?, expires_at = ?, updated_at = ?, version = version + 1, stage = NULL WHERE id = ? AND state = 'VERIFYING' AND worker_pid = ?");
    if !stmt.ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    sqlite3_bind_int64(stmt.h, 1, output_bytes);
    sqlite3_bind_int64(stmt.h, 2, expires);
    sqlite3_bind_int64(stmt.h, 3, now);
    bind_text(stmt.h, 4, id);
    sqlite3_bind_int64(stmt.h, 5, c_getpid());
    let ok = sqlite3_step(stmt.h) == SQLITE_DONE && sqlite3_changes(handle) > 0;
    release(stmt);
    if !ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    let estmt = prepare("INSERT INTO job_events(job_id, at, from_state, to_state, code) VALUES(?, ?, NULL, 'READY', NULL)");
    if !estmt.ok { exec_raw("ROLLBACK;"); close_req(); return false; }
    bind_text(estmt.h, 1, id);
    sqlite3_bind_int64(estmt.h, 2, now);
    let eok = sqlite3_step(estmt.h) == SQLITE_DONE;
    release(estmt);
    if !eok || !exec_raw("COMMIT;") { exec_raw("ROLLBACK;"); close_req(); return false; }
    close_req();
    return true;
}

// Requeues a terminal job for another attempt (bounded by the caller).
fn requeue(id: u8[:], now: i64) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("UPDATE jobs SET state = 'QUEUED', stage = NULL, downloaded_bytes = 0, total_bytes = NULL, speed_bps = NULL, eta_seconds = NULL, output_bytes = NULL, worker_pid = NULL, child_pid = NULL, error_code = NULL, error_detail = NULL, expires_at = NULL, retry_count = retry_count + 1, updated_at = ?, version = version + 1 WHERE id = ? AND state IN ('FAILED','CANCELLED') AND retry_count < 3");
    var ok = false;
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        bind_text(stmt.h, 2, id);
        ok = sqlite3_step(stmt.h) == SQLITE_DONE && sqlite3_changes(handle) > 0;
        release(stmt);
    }
    if ok {
        let estmt = prepare("INSERT INTO job_events(job_id, at, from_state, to_state, code) VALUES(?, ?, NULL, 'QUEUED', 'RETRY')");
        if estmt.ok {
            bind_text(estmt.h, 1, id);
            sqlite3_bind_int64(estmt.h, 2, now);
            ok = sqlite3_step(estmt.h) == SQLITE_DONE;
            release(estmt);
        } else { ok = false; }
    }
    close_req();
    return ok;
}

fn bump_retry(id: u8[:], now: i64) {
    if !open_req() { return; }
    let stmt = prepare("UPDATE jobs SET retry_count = retry_count + 1, updated_at = ? WHERE id = ?");
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        bind_text(stmt.h, 2, id);
        sqlite3_step(stmt.h);
        release(stmt);
    }
    close_req();
}

fn count_active() -> i64 {
    if !open_req() { return 0; }
    let stmt = prepare("SELECT COUNT(*) FROM jobs WHERE state IN ('QUEUED','DOWNLOADING','VERIFYING')");
    var r = 0;
    if stmt.ok {
        if sqlite3_step(stmt.h) == SQLITE_ROW { r = sqlite3_column_int64(stmt.h, 0); }
        release(stmt);
    }
    close_req();
    return r;
}

fn oldest_queued(scratch: u8[>..]&) -> Job, bool {
    if !open_req() { return empty_job(), false; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    sql.append(JOB_COLS);
    sql.append(" FROM jobs WHERE state = 'QUEUED' ORDER BY created_at, id LIMIT 1");
    var r = empty_job();
    var ok = false;
    let stmt = prepare(sql);
    if stmt.ok {
        if sqlite3_step(stmt.h) == SQLITE_ROW { r = read_job_row(stmt, scratch); ok = true; }
        release(stmt);
    }
    close_req();
    return r, ok;
}

// Job ids of interrupted work (active states), for startup recovery.
fn interrupted_jobs(scratch: u8[>..]&) -> Job[>..] {
    if !open_req() { var _none: Job[>..] = []; return _none; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    sql.append(JOB_COLS);
    sql.append(" FROM jobs WHERE state IN ('DOWNLOADING','VERIFYING') ORDER BY created_at");
    var out: Job[>..] = [];
    let stmt = prepare(sql);
    if stmt.ok {
        while sqlite3_step(stmt.h) == SQLITE_ROW {
            out.push(read_job_row(stmt, scratch));
        }
        release(stmt);
    }
    close_req();
    return out;
}

// Ready jobs past expiry.
fn expired_ready(scratch: u8[>..]&, now: i64) -> Job[>..] {
    if !open_req() { var _none: Job[>..] = []; return _none; }
    var sql: u8[>..] = [];
    sql.append("SELECT ");
    sql.append(JOB_COLS);
    sql.append(" FROM jobs WHERE state = 'READY' AND expires_at IS NOT NULL AND expires_at <= ? ORDER BY expires_at");
    var out: Job[>..] = [];
    let stmt = prepare(sql);
    if stmt.ok {
        sqlite3_bind_int64(stmt.h, 1, now);
        while sqlite3_step(stmt.h) == SQLITE_ROW {
            out.push(read_job_row(stmt, scratch));
        }
        release(stmt);
    }
    close_req();
    return out;
}

// Resets interrupted active jobs (DOWNLOADING/VERIFYING) to QUEUED for a
// retry, or FAILED when retries are exhausted. Returns job ids recovered.
fn recover_interrupted(now: i64, scratch: u8[>..]&) -> Job[>..] {
    if !open_req() { var _none: Job[>..] = []; return _none; }
    let found = interrupted_jobs(scratch);
    for j in found {
        let stmt = prepare("UPDATE jobs SET state = 'QUEUED', stage = NULL, downloaded_bytes = 0, total_bytes = NULL, speed_bps = NULL, eta_seconds = NULL, worker_pid = NULL, child_pid = NULL, updated_at = ?, version = version + 1 WHERE id = ? AND retry_count < 3 AND state IN ('DOWNLOADING','VERIFYING')");
        if stmt.ok {
            sqlite3_bind_int64(stmt.h, 1, now);
            bind_text(stmt.h, 2, j.id);
            sqlite3_step(stmt.h);
            release(stmt);
        }
        if j.retry_count >= 3 {
            set_failure(j.id, "RECOVERED", "Interrupted by a restart with no retries left.", now);
        }
    }
    close_req();
    return found;
}

fn delete_job(id: u8[:]) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("DELETE FROM jobs WHERE id = ?");
    var r = false;
    if stmt.ok {
        bind_text(stmt.h, 1, id);
        r = sqlite3_step(stmt.h) == SQLITE_DONE;
        release(stmt);
    }
    close_req();
    return r;
}

// --- backup / integrity --------------------------------------------------------

fn integrity(scratch: u8[>..]&) -> bool {
    if !open_req() { return false; }
    let stmt = prepare("PRAGMA integrity_check");
    var r = false;
    if stmt.ok {
        if sqlite3_step(stmt.h) == SQLITE_ROW {
            let start = scratch.len;
            ffi::cstr(sqlite3_column_text(stmt.h, 0), scratch);
            r = scratch[start..] == "ok";
        }
        release(stmt);
    }
    close_req();
    return r;
}

fn backup_to(out_path: u8[:]) -> bool {
    if !open_req() { return false; }
    var outb: u8[>..] = [];
    outb.append(out_path);
    outb.push(0);
    var mainb: u8[>..] = [];
    mainb.append("main");
    mainb.push(0);
    let b = sqlite3_backup_init(handle, outb[0], handle, mainb[0]);
    var r = false;
    if b != 0 {
        let rc = sqlite3_backup_step(b, -1);
        let fin = sqlite3_backup_finish(b);
        r = rc == SQLITE_OK && fin == SQLITE_OK;
    }
    close_req();
    return r;
}
