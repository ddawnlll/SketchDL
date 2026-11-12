// Password hashing (Argon2id via libargon2), session tokens, and the
// login limiter. SHA-256 and hex are pure Goose (crypto.goose).
namespace auth;

import std;
import crypto;
import util;

// Only hash_encoded and verify are bound: this system's argon2_encodedlen
// takes an argon2_type where upstream documents hashlen (verified by
// probing the installed libargon2: it passes the 6th argument to
// argon2_type2string, so a hash length segfaults in strlen). The encoded
// length is computed inline instead; it only sizes the output buffer.
extern "libargon2.so.1" {
    fn argon2id_hash_encoded(t_cost: u32, m_cost: u32, parallelism: u32, pwd: const u8&, pwd_len: u32, salt: const u8&, salt_len: u32, hash_len: u32, out: u8&, out_len: u32) -> i32;
    fn argon2id_verify(encoded: const u8&, pwd: const u8&, pwd_len: u32) -> i32;
}

const MIN_PASSWORD = 12;
const MAX_PASSWORD = 1024;

const ARGON_T = 2;
const ARGON_M = 19456;
const ARGON_P = 1;
const ARGON_SALT = 16;
const ARGON_HASH = 32;

// 0 ok, 1 too short, 2 too long, 3 bad UTF-8.
fn validate_password(password: u8[:]) -> i64 {
    if password.len < MIN_PASSWORD { return 1; }
    if password.len > MAX_PASSWORD { return 2; }
    if !util::utf8_valid(password) { return 3; }
    return 0;
}

fn digits(n: u32) -> i64 {
    var d = 1;
    var v = n;
    while v >= 10 { v /= 10; d += 1; }
    return d;
}

// Length of the PHC string argon2id_hash_encoded writes, plus its NUL:
// "$argon2id$v=19$m=<m>,t=<t>,p=<p>$<b64 salt>$<b64 hash>" unpadded base64.
fn encoded_len(t_cost: u32, m_cost: u32, parallelism: u32, salt_len: u32, hash_len: u32) -> i64 {
    return 17 + digits(m_cost) + 3 + digits(t_cost) + 3 + digits(parallelism) + 1
        + (salt_len * 8 + 5) / 6 + 1 + (hash_len * 8 + 5) / 6 + 1;
}

fn hash_password(out: u8[>..]&, password: u8[:]) -> bool {
    var salt: u8[>..] = [];
    if !crypto::random_bytes(salt, ARGON_SALT) { return false; }
    var pwd: u8[>..] = [];
    pwd.append(password);
    let need = encoded_len(ARGON_T, ARGON_M, ARGON_P, ARGON_SALT, ARGON_HASH) as u32;
    var enc: u8[>..] = [];
    enc.resize(need, 0);
    let rc = argon2id_hash_encoded(ARGON_T, ARGON_M, ARGON_P, pwd[0], pwd.len as u32, salt[0], ARGON_SALT, ARGON_HASH, enc[0], need);
    if rc != 0 { return false; }
    var len = 0;
    while len < enc.len && enc[len] != 0 { len += 1; }
    out.append(enc[..len]);
    return true;
}

fn verify_password(stored: u8[:], password: u8[:]) -> bool {
    if password.len > MAX_PASSWORD { return false; }
    if !starts_with(stored, "$argon2id$") { return false; }
    if stored.len == 0 || stored.len > 512 { return false; }
    var enc: u8[>..] = [];
    enc.append(stored);
    enc.push(0);
    var pwd: u8[>..] = [];
    pwd.append(password);
    if pwd.len == 0 { pwd.push(0); }
    return argon2id_verify(enc[0], pwd[0], password.len as u32) == 0;
}

// Mints a session token and CSRF secret. token is the hex cookie value,
// token_hash the hex SHA-256 of the raw token bytes (what the DB stores),
// csrf the hex CSRF secret.
fn new_session(token: u8[>..]&, token_hash: u8[>..]&, csrf: u8[>..]&) -> bool {
    var raw: u8[>..] = [];
    var csrf_raw: u8[>..] = [];
    if !crypto::random_bytes(raw, 32) { return false; }
    if !crypto::random_bytes(csrf_raw, 32) { return false; }
    crypto::hex_lower(token, raw);
    let digest = crypto::sha256_hex(raw);
    token_hash.append(digest);
    crypto::hex_lower(csrf, csrf_raw);
    return true;
}

// SHA-256 hex of a hex session token from a cookie. False if malformed.
fn token_hash_from_hex(token_hex: u8[:], out: u8[>..]&) -> bool {
    if token_hex.len != 64 { return false; }
    var raw: u8[>..] = [];
    if !crypto::hex_decode(raw, token_hex) { return false; }
    if raw.len != 32 { return false; }
    let digest = crypto::sha256_hex(raw);
    out.append(digest);
    return true;
}

fn csrf_matches(expected_hex: u8[:], supplied_hex: u8[:]) -> bool {
    if expected_hex.len != 64 || supplied_hex.len != 64 { return false; }
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    if !crypto::hex_decode(a, expected_hex) { return false; }
    if !crypto::hex_decode(b, supplied_hex) { return false; }
    if a.len != 32 || b.len != 32 { return false; }
    return crypto::timing_eq(a, b);
}

// --- LoginLimiter: fixed-size, in-process, bounds guessing work -----------

const LIM_MAX = 128;
const LIM_WINDOW = 15 * 60;
const LIM_FAILURES = 5;
const LIM_CONCURRENT = 2;

struct LimEntry { key: u8[64], key_len: i64, failures: i64, window_start: i64 }

var lim_entries: LimEntry[128] = [LimEntry { key: [0; 64], key_len: 0, failures: 0, window_start: 0 }; 128];
var lim_next = 0;
var lim_active = 0;

fn lim_init() {
    for i in LIM_MAX { lim_entries[i] = LimEntry { key: [0; 64], key_len: 0, failures: 0, window_start: 0 }; }
}

// Returns ticket (or -1), limited, busy.
fn lim_begin(key: u8[:], now: i64) -> i64, bool, bool {
    var clipped = key;
    if clipped.len > 64 { clipped = clipped[..64]; }
    var idx = -1;
    for i in LIM_MAX {
        let e = lim_entries[i];
        if e.key_len != 0 && e.key_len == clipped.len {
            var same = true;
            for j in clipped.len { if e.key[j] != clipped[j] { same = false; } }
            if same {
                if now - e.window_start >= LIM_WINDOW {
                    lim_entries[i].failures = 0;
                    lim_entries[i].window_start = now;
                }
                idx = i;
            }
        }
        if idx >= 0 { break; }
    }
    if idx < 0 {
        var cand = lim_next;
        for _ in LIM_MAX {
            if lim_entries[cand].key_len == 0 || now - lim_entries[cand].window_start >= LIM_WINDOW { break; }
            cand = (cand + 1) % LIM_MAX;
        }
        lim_next = (cand + 1) % LIM_MAX;
        lim_entries[cand].key_len = clipped.len;
        for j in clipped.len { lim_entries[cand].key[j] = clipped[j]; }
        lim_entries[cand].failures = 0;
        lim_entries[cand].window_start = now;
        idx = cand;
    }
    let entry = lim_entries[idx];
    if entry.failures >= LIM_FAILURES && now - entry.window_start < LIM_WINDOW {
        return -1, true, false;
    }
    if lim_active >= LIM_CONCURRENT { return -1, false, true; }
    lim_active += 1;
    return idx, false, false;
}

fn lim_finish(ticket: i64, success: bool, now: i64) {
    if lim_active > 0 { lim_active -= 1; }
    if ticket < 0 || ticket >= LIM_MAX { return; }
    if success {
        lim_entries[ticket].failures = 0;
        lim_entries[ticket].window_start = now;
    } else {
        if now - lim_entries[ticket].window_start >= LIM_WINDOW {
            lim_entries[ticket].window_start = now;
            lim_entries[ticket].failures = 1;
        } else {
            lim_entries[ticket].failures += 1;
        }
    }
}
