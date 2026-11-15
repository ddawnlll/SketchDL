use rusqlite::{Connection, OptionalExtension, params};
use std::path::Path;
use std::sync::{Mutex, MutexGuard};

pub const SCHEMA: &str = include_str!("../../migrations/0001_init.sql");

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Clone, Debug, Default)]
pub struct Job {
    pub id: String,
    pub video_id: String,
    pub title: Option<String>,
    pub preset: String,
    pub format_id: Option<String>,
    pub state: String,
    pub stage: Option<String>,
    pub downloaded_bytes: i64,
    pub total_bytes: Option<i64>,
    pub speed_bps: Option<i64>,
    pub eta_seconds: Option<i64>,
    pub output_bytes: Option<i64>,
    pub worker_pid: Option<i64>,
    pub child_pid: Option<i64>,
    pub error_code: Option<String>,
    pub error_detail: Option<String>,
    pub retry_count: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub expires_at: Option<i64>,
    pub version: i64,
}

#[derive(Clone, Debug, Default)]
pub struct Inspection {
    pub video_id: String,
    pub title: String,
    pub duration: Option<i64>,
    pub formats_json: String,
}

pub struct Db {
    conn: Mutex<Connection>,
}

fn open_conn(path: &str) -> rusqlite::Result<Connection> {
    if let Some(parent) = Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_millis(5000))?;
    c.execute_batch(
        "PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;",
    )?;
    Ok(c)
}

impl Db {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let c = open_conn(path)?;
        migrate(&c)?;
        Ok(Self {
            conn: Mutex::new(c),
        })
    }

    pub fn lock(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn has_owner(&self) -> bool {
        self.lock()
            .query_row("SELECT 1 FROM owner WHERE id = 1", [], |_| Ok(()))
            .optional()
            .ok()
            .flatten()
            .is_some()
    }

    pub fn set_owner_hash(&self, hash: &str, at: i64) -> rusqlite::Result<()> {
        let c = self.lock();
        c.execute(
            "INSERT INTO owner(id, password_hash, created_at) VALUES(1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET password_hash = excluded.password_hash",
            params![hash, at],
        )?;
        Ok(())
    }

    pub fn owner_hash(&self) -> Option<String> {
        self.lock()
            .query_row("SELECT password_hash FROM owner WHERE id = 1", [], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten()
    }

    pub fn create_session(
        &self,
        token_hash: &str,
        csrf: &str,
        now: i64,
        expires: i64,
    ) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT INTO sessions(token_hash, owner_id, csrf_token, issued_at, last_used_at, expires_at)
             VALUES(?1, 1, ?2, ?3, ?3, ?4)",
            params![token_hash, csrf, now, expires],
        )?;
        Ok(())
    }

    /// Returns (csrf, expires_at) for a live session and touches it.
    pub fn find_session(&self, token_hash: &str, now: i64) -> Option<(String, i64)> {
        let c = self.lock();
        let row = c
            .query_row(
                "SELECT csrf_token, expires_at FROM sessions
                 WHERE token_hash = ?1 AND revoked = 0 AND expires_at > ?2",
                params![token_hash, now],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
            )
            .optional()
            .ok()
            .flatten();
        if row.is_some() {
            let _ = c.execute(
                "UPDATE sessions SET last_used_at = ?1 WHERE token_hash = ?2",
                params![now, token_hash],
            );
        }
        row
    }

    pub fn revoke_session(&self, token_hash: &str) {
        let _ = self.lock().execute(
            "UPDATE sessions SET revoked = 1 WHERE token_hash = ?1",
            params![token_hash],
        );
    }

    pub fn delete_expired_sessions(&self, now: i64) {
        let _ = self
            .lock()
            .execute("DELETE FROM sessions WHERE expires_at <= ?1", params![now]);
    }

    pub fn store_inspection(
        &self,
        token_hash: &str,
        video_id: &str,
        title: &str,
        duration: Option<i64>,
        formats_json: &str,
        expires: i64,
    ) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT OR REPLACE INTO inspections(token_hash, owner_id, video_id, title, duration, formats_json, expires_at)
             VALUES(?1, 1, ?2, ?3, ?4, ?5, ?6)",
            params![token_hash, video_id, title, duration, formats_json, expires],
        )?;
        Ok(())
    }

    pub fn find_inspection(&self, token_hash: &str, now: i64) -> Option<Inspection> {
        self.lock()
            .query_row(
                "SELECT video_id, title, duration, formats_json FROM inspections
                 WHERE token_hash = ?1 AND expires_at > ?2",
                params![token_hash, now],
                |r| {
                    Ok(Inspection {
                        video_id: r.get(0)?,
                        title: r.get(1)?,
                        duration: r.get(2)?,
                        formats_json: r.get(3)?,
                    })
                },
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn delete_inspection(&self, token_hash: &str) {
        let _ = self.lock().execute(
            "DELETE FROM inspections WHERE token_hash = ?1",
            params![token_hash],
        );
    }

    pub fn delete_expired_inspections(&self, now: i64) {
        let _ = self.lock().execute(
            "DELETE FROM inspections WHERE expires_at <= ?1",
            params![now],
        );
    }

    pub fn create_job(
        &self,
        id: &str,
        video_id: &str,
        title: &str,
        preset: &str,
        format_id: &str,
        now: i64,
    ) -> rusqlite::Result<()> {
        self.lock().execute(
            "INSERT INTO jobs(id, owner_id, video_id, title, preset, format_id, state, created_at, updated_at)
             VALUES(?1, 1, ?2, ?3, ?4, ?5, 'QUEUED', ?6, ?6)",
            params![id, video_id, title, preset, format_id, now],
        )?;
        Ok(())
    }

    pub fn find_job(&self, id: &str) -> Option<Job> {
        self.lock()
            .query_row(
                "SELECT id, video_id, title, preset, format_id, state, stage,
                        downloaded_bytes, total_bytes, speed_bps, eta_seconds,
                        output_bytes, worker_pid, child_pid, error_code,
                        error_detail, retry_count, created_at, updated_at,
                        expires_at, version
                 FROM jobs WHERE id = ?1",
                params![id],
                row_to_job,
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn list_jobs(&self, limit: i64) -> Vec<Job> {
        let c = self.lock();
        let mut stmt = match c.prepare_cached(
            "SELECT id, video_id, title, preset, format_id, state, stage,
                    downloaded_bytes, total_bytes, speed_bps, eta_seconds,
                    output_bytes, worker_pid, child_pid, error_code,
                    error_detail, retry_count, created_at, updated_at,
                    expires_at, version
             FROM jobs ORDER BY created_at DESC, id DESC LIMIT ?1",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let rows = stmt.query_map(params![limit], row_to_job);
        match rows {
            Ok(r) => r.filter_map(Result::ok).collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn transition(&self, id: &str, from: &str, to: &str, now: i64, code: Option<&str>) -> bool {
        let mut c = self.lock();
        let tx = match c.transaction() {
            Ok(t) => t,
            Err(_) => return false,
        };
        let changed = tx
            .execute(
                "UPDATE jobs SET state = ?1, updated_at = ?2, version = version + 1
                 WHERE id = ?3 AND state = ?4",
                params![to, now, id, from],
            )
            .unwrap_or(0);
        if changed == 0 {
            return false;
        }
        let _ = tx.execute(
            "INSERT INTO job_events(job_id, at, from_state, to_state, code)
             VALUES(?1, ?2, ?3, ?4, ?5)",
            params![id, now, from, to, code],
        );
        tx.commit().is_ok()
    }

    pub fn set_worker(&self, id: &str, worker_pid: i64, child_pid: Option<i64>, now: i64) {
        let _ = self.lock().execute(
            "UPDATE jobs SET worker_pid = ?1, child_pid = ?2, updated_at = ?3,
                    version = version + 1
             WHERE id = ?4 AND state = 'DOWNLOADING'",
            params![worker_pid, child_pid, now, id],
        );
    }

    pub fn update_progress(
        &self,
        id: &str,
        worker_pid: i64,
        stage: &str,
        downloaded: i64,
        total: Option<i64>,
        speed: Option<i64>,
        eta: Option<i64>,
        now: i64,
    ) {
        let _ = self.lock().execute(
            "UPDATE jobs SET stage = ?1, downloaded_bytes = ?2, total_bytes = ?3,
                    speed_bps = ?4, eta_seconds = ?5, updated_at = ?6,
                    version = version + 1
             WHERE id = ?7 AND worker_pid = ?8 AND state = 'DOWNLOADING'",
            params![stage, downloaded, total, speed, eta, now, id, worker_pid],
        );
    }

    pub fn set_stage(&self, id: &str, stage: &str, now: i64) {
        let _ = self.lock().execute(
            "UPDATE jobs SET stage = ?1, updated_at = ?2 WHERE id = ?3",
            params![stage, now, id],
        );
    }

    pub fn set_failure(&self, id: &str, code: &str, detail: &str, now: i64) -> bool {
        let c = self.lock();
        let from: Option<String> = c
            .query_row("SELECT state FROM jobs WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten();
        let changed = c
            .execute(
                "UPDATE jobs SET state = 'FAILED', error_code = ?1, error_detail = ?2,
                        updated_at = ?3, version = version + 1
                 WHERE id = ?4 AND state IN ('DOWNLOADING','VERIFYING')",
                params![code, detail, now, id],
            )
            .unwrap_or(0)
            > 0;
        if changed {
            let _ = c.execute(
                "INSERT INTO job_events(job_id, at, from_state, to_state, code)
                 VALUES(?1, ?2, ?3, 'FAILED', ?4)",
                params![id, now, from, code],
            );
        }
        changed
    }

    pub fn set_ready(&self, id: &str, bytes: i64, expires: i64, now: i64) -> bool {
        let c = self.lock();
        let changed = c
            .execute(
                "UPDATE jobs SET state = 'READY', output_bytes = ?1, expires_at = ?2,
                        stage = NULL, speed_bps = NULL, eta_seconds = NULL,
                        updated_at = ?3, version = version + 1
                 WHERE id = ?4 AND state = 'VERIFYING'",
                params![bytes, expires, now, id],
            )
            .unwrap_or(0)
            > 0;
        if changed {
            let _ = c.execute(
                "INSERT INTO job_events(job_id, at, from_state, to_state, code)
                 VALUES(?1, ?2, 'VERIFYING', 'READY', 'PUBLISH')",
                params![id, now],
            );
        }
        changed
    }

    pub fn cancel(&self, id: &str, now: i64) -> bool {
        let c = self.lock();
        let from: Option<String> = c
            .query_row("SELECT state FROM jobs WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()
            .ok()
            .flatten();
        let Some(from_state) = from else {
            return false;
        };
        if !matches!(from_state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING") {
            return false;
        }
        let changed = c
            .execute(
                "UPDATE jobs SET state = 'CANCELLED', stage = NULL, speed_bps = NULL,
                        eta_seconds = NULL, updated_at = ?1, version = version + 1
                 WHERE id = ?2 AND state = ?3",
                params![now, id, from_state],
            )
            .unwrap_or(0)
            > 0;
        if changed {
            let _ = c.execute(
                "INSERT INTO job_events(job_id, at, from_state, to_state, code)
                 VALUES(?1, ?2, ?3, 'CANCELLED', 'CANCEL')",
                params![id, now, from_state],
            );
        }
        changed
    }

    pub fn requeue(&self, id: &str, now: i64, code: &str) -> bool {
        let c = self.lock();
        let changed = c
            .execute(
                "UPDATE jobs SET state = 'QUEUED', stage = NULL, downloaded_bytes = 0,
                        total_bytes = NULL, speed_bps = NULL, eta_seconds = NULL,
                        output_bytes = NULL, worker_pid = NULL, child_pid = NULL,
                        error_code = NULL, error_detail = NULL,
                        retry_count = retry_count + 1, updated_at = ?1,
                        version = version + 1
                 WHERE id = ?2 AND state IN ('FAILED','CANCELLED','DOWNLOADING','VERIFYING')
                   AND retry_count < 3",
                params![now, id],
            )
            .unwrap_or(0)
            > 0;
        if changed {
            let _ = c.execute(
                "INSERT INTO job_events(job_id, at, from_state, to_state, code)
                 VALUES(?1, ?2, 'RETRY', 'QUEUED', ?3)",
                params![id, now, code],
            );
        }
        changed
    }

    pub fn delete_job(&self, id: &str) {
        let _ = self
            .lock()
            .execute("DELETE FROM jobs WHERE id = ?1", params![id]);
    }

    pub fn active_jobs(&self) -> Vec<Job> {
        let c = self.lock();
        let mut stmt = match c.prepare_cached(
            "SELECT id, video_id, title, preset, format_id, state, stage,
                    downloaded_bytes, total_bytes, speed_bps, eta_seconds,
                    output_bytes, worker_pid, child_pid, error_code,
                    error_detail, retry_count, created_at, updated_at,
                    expires_at, version
             FROM jobs WHERE state IN ('DOWNLOADING','VERIFYING')",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        match stmt.query_map([], row_to_job) {
            Ok(r) => r.filter_map(Result::ok).collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn expired_ready(&self, now: i64) -> Vec<Job> {
        let c = self.lock();
        let mut stmt = match c.prepare_cached(
            "SELECT id, video_id, title, preset, format_id, state, stage,
                    downloaded_bytes, total_bytes, speed_bps, eta_seconds,
                    output_bytes, worker_pid, child_pid, error_code,
                    error_detail, retry_count, created_at, updated_at,
                    expires_at, version
             FROM jobs WHERE state = 'READY' AND expires_at IS NOT NULL AND expires_at <= ?1",
        ) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        match stmt.query_map(params![now], row_to_job) {
            Ok(r) => r.filter_map(Result::ok).collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn expire_ready(&self, id: &str, now: i64) -> bool {
        let c = self.lock();
        let changed = c
            .execute(
                "UPDATE jobs SET state = 'EXPIRED', updated_at = ?1, version = version + 1
                 WHERE id = ?2 AND state = 'READY'",
                params![now, id],
            )
            .unwrap_or(0)
            > 0;
        if changed {
            let _ = c.execute(
                "INSERT INTO job_events(job_id, at, from_state, to_state, code)
                 VALUES(?1, ?2, 'READY', 'EXPIRED', 'EXPIRE')",
                params![id, now],
            );
        }
        changed
    }

    pub fn backup_to(&self, out: &str) -> rusqlite::Result<()> {
        let c = self.lock();
        c.execute("VACUUM INTO ?1", params![out])?;
        Ok(())
    }

    pub fn integrity(&self) -> bool {
        self.lock()
            .query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0))
            .map(|s| s == "ok")
            .unwrap_or(false)
    }
}

fn migrate(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);")?;
    let version: i64 = c
        .query_row("SELECT version FROM schema_meta LIMIT 1", [], |r| r.get(0))
        .optional()?
        .unwrap_or(0);
    if version == 0 {
        c.execute_batch("BEGIN IMMEDIATE;")?;
        if let Err(e) = c.execute_batch(SCHEMA) {
            let _ = c.execute_batch("ROLLBACK;");
            return Err(e);
        }
        c.execute_batch(
            "INSERT INTO schema_meta(version) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);
             UPDATE schema_meta SET version = 1;
             COMMIT;",
        )?;
    }
    Ok(())
}

fn row_to_job(r: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    Ok(Job {
        id: r.get(0)?,
        video_id: r.get(1)?,
        title: r.get(2)?,
        preset: r.get(3)?,
        format_id: r.get(4)?,
        state: r.get(5)?,
        stage: r.get(6)?,
        downloaded_bytes: r.get(7)?,
        total_bytes: r.get(8)?,
        speed_bps: r.get(9)?,
        eta_seconds: r.get(10)?,
        output_bytes: r.get(11)?,
        worker_pid: r.get(12)?,
        child_pid: r.get(13)?,
        error_code: r.get(14)?,
        error_detail: r.get(15)?,
        retry_count: r.get(16)?,
        created_at: r.get(17)?,
        updated_at: r.get(18)?,
        expires_at: r.get(19)?,
        version: r.get(20)?,
    })
}
