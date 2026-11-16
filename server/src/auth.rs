use argon2::Argon2;
use argon2::password_hash::{PasswordHasher, PasswordVerifier, SaltString};
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub fn random_hex(n: usize) -> String {
    let mut buf = vec![0u8; n];
    rand::rng().fill_bytes(&mut buf);
    hex::encode(buf)
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex::encode(h.finalize())
}

pub fn hash_password(password: &str) -> Option<String> {
    let mut salt_bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut salt_bytes);
    let salt = SaltString::encode_b64(&salt_bytes).ok()?;
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .ok()
        .map(|h| h.to_string())
}

pub fn verify_password(hash: &str, password: &str) -> bool {
    let parsed = match argon2::password_hash::PasswordHash::new(hash) {
        Ok(p) => p,
        Err(_) => return false,
    };
    Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok()
}

pub fn valid_password_bytes(pw: &str) -> bool {
    let n = pw.len();
    (12..=1024).contains(&n) && std::str::from_utf8(pw.as_bytes()).is_ok()
}

pub fn cookie_name(secure: bool) -> &'static str {
    if secure {
        "__Host-sketchdl_session"
    } else {
        "sketchdl_session"
    }
}

pub fn session_cookie(token: &str, max_age: i64, secure: bool) -> String {
    let mut c = format!(
        "{}={}; Path=/; HttpOnly; SameSite=Lax; Max-Age={}",
        cookie_name(secure),
        token,
        max_age
    );
    if secure {
        c.push_str("; Secure");
    }
    c
}

pub fn clear_cookie(secure: bool) -> String {
    let mut c = format!(
        "{}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
        cookie_name(secure)
    );
    if secure {
        c.push_str("; Secure");
    }
    c
}

pub fn parse_cookie(header: &str, name: &str) -> Option<String> {
    for part in header.split(';') {
        let part = part.trim();
        if let Some((k, v)) = part.split_once('=') {
            if k == name {
                return Some(v.to_string());
            }
        }
    }
    None
}

pub fn csrf_ok(expected: &str, provided: &str) -> bool {
    expected.len() == provided.len()
        && expected
            .bytes()
            .zip(provided.bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

pub struct LoginLimiter {
    inner: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl LoginLimiter {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }

    fn prune(&self, q: &mut VecDeque<Instant>) {
        let cutoff = Instant::now() - Duration::from_secs(15 * 60);
        while q.front().is_some_and(|t| *t < cutoff) {
            q.pop_front();
        }
    }

    /// True when this IP is currently blocked.
    pub fn blocked(&self, ip: &str) -> bool {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let q = map.entry(ip.to_string()).or_default();
        self.prune(q);
        q.len() >= 5
    }

    pub fn fail(&self, ip: &str) {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let q = map.entry(ip.to_string()).or_default();
        self.prune(q);
        q.push_back(Instant::now());
    }

    pub fn success(&self, ip: &str) {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        map.remove(ip);
    }
}
