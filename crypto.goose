// Crypto primitives written in Goose: SHA-256, hex, secure randomness,
// constant-time comparison. Argon2id itself comes from libargon2 (see
// auth.goose); everything else is pure Goose so the core logic stays in
// the language under test.
namespace crypto;

import std;

extern fn c_getrandom(buf: u8&, count: u64, flags: u32) -> i64 = "getrandom";

fn random_bytes(out: u8[>..]&, n: i64) -> bool {
    let start = out.len;
    out.resize(start + n, 0);
    var done = 0;
    while done < n {
        let got = c_getrandom(out[start + done], (n - done) as u64, 0);
        if got <= 0 { out.resize(start); return false; }
        done += got;
    }
    return true;
}

fn hex_lower(out: u8[>..]&, data: u8[:]) {
    let hexd = "0123456789abcdef";
    for b in data {
        out.push(hexd[b >> 4]);
        out.push(hexd[b & 15]);
    }
}

fn hex_decode(out: u8[>..]&, text: u8[:]) -> bool {
    if text.len % 2 != 0 { return false; }
    var i = 0;
    while i < text.len {
        let hi = hex_val(text[i]);
        let lo = hex_val(text[i + 1]);
        if hi < 0 || lo < 0 { return false; }
        out.push(((hi << 4) | lo) as u8);
        i += 2;
    }
    return true;
}

fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn timing_eq(a: u8[:], b: u8[:]) -> bool {
    if a.len != b.len { return false; }
    var diff: u8 = 0;
    for i in a.len { diff |= a[i] ^ b[i]; }
    return diff == 0;
}

// --- SHA-256 (FIPS 180-4) -------------------------------------------------

const K: u32[64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

fn rotr(x: u32, n: u32) -> u32 { return (x >> n) | (x << (32 - n)); }

fn sha256(data: u8[:], out: u8[>..]&) {
    // NB: the `as u32` casts below are required: without them the shifts
    // truncate to u8 and the digest is wrong (the compiler's redundant-cast
    // note here is incorrect).
    let start = out.len;
    var h: u32[8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var msg: u8[>..] = [];
    msg.append(data);
    let bit_len = (data.len as u64) * 8;
    msg.push(128);
    while msg.len % 64 != 56 { msg.push(0); }
    var i = 8;
    while i > 0 {
        i -= 1;
        msg.push((bit_len >> (8 * i)) as u8);
    }
    var blk = 0;
    while blk < msg.len {
        var w: u32[64] = [0; 64];
        var t = 0;
        while t < 16 {
            let p = blk + t * 4;
            w[t] = (((msg[p] as u32) << 24) | ((msg[p + 1] as u32) << 16) | ((msg[p + 2] as u32) << 8) | (msg[p + 3] as u32));
            t += 1;
        }
        while t < 64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
            w[t] = w[t - 16] + s0 + w[t - 7] + s1;
            t += 1;
        }
        var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3];
        var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7];
        var t2 = 0;
        while t2 < 64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            let ch = (e & f) ^ (~e & g);
            let t1 = hh + s1 + ch + K[t2] + w[t2];
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t12 = s0 + maj;
            hh = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t12;
            t2 += 1;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
        blk += 64;
    }
    var hi = 0;
    while hi < 8 {
        out.push((h[hi] >> 24) as u8);
        out.push((h[hi] >> 16) as u8);
        out.push((h[hi] >> 8) as u8);
        out.push(h[hi] as u8);
        hi += 1;
    }
    let _ = start;
}

fn sha256_hex(data: u8[:]) -> u8[>..] {
    var raw: u8[>..] = [];
    sha256(data, raw);
    var hex: u8[>..] = [];
    hex_lower(hex, raw);
    return hex;
}
