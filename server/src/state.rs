use crate::auth::LoginLimiter;
use crate::config::Config;
use crate::db::{Db, Job};
use crate::views;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use tokio::sync::{Semaphore, broadcast};

pub struct EventBus {
    map: Mutex<HashMap<String, broadcast::Sender<String>>>,
}

impl EventBus {
    pub fn new() -> Self {
        Self {
            map: Mutex::new(HashMap::new()),
        }
    }

    pub fn channel(&self, id: &str) -> broadcast::Receiver<String> {
        let mut map = self.map.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(tx) = map.get(id) {
            return tx.subscribe();
        }
        let (tx, rx) = broadcast::channel(128);
        map.insert(id.to_string(), tx);
        rx
    }

    pub fn publish(&self, id: &str, json: String) {
        let map = self.map.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(tx) = map.get(id) {
            let _ = tx.send(json);
        }
    }

    pub fn close(&self, id: &str) {
        let mut map = self.map.lock().unwrap_or_else(|e| e.into_inner());
        map.remove(id);
    }
}

pub struct AppState {
    pub cfg: Config,
    pub db: Arc<Db>,
    pub events: EventBus,
    pub cancelled: Mutex<HashSet<String>>,
    pub permits: Semaphore,
    pub limiter: LoginLimiter,
}

impl AppState {
    pub fn new(cfg: Config) -> Result<Arc<Self>, String> {
        let db = Db::open(&cfg.db).map_err(|e| format!("open database: {e}"))?;
        let permits = Semaphore::new(cfg.max_active.clamp(1, 32) as usize);
        Ok(Arc::new(Self {
            db: Arc::new(db),
            cfg,
            events: EventBus::new(),
            cancelled: Mutex::new(HashSet::new()),
            permits,
            limiter: LoginLimiter::new(),
        }))
    }

    pub fn publish_job(&self, job: &Job) {
        self.events.publish(&job.id, views::sse_progress(job));
    }

    pub fn publish_current(&self, id: &str) {
        if let Some(job) = self.db.find_job(id) {
            self.publish_job(&job);
            if !matches!(job.state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING") {
                self.events.close(id);
            }
        }
    }

    pub fn is_cancelled(&self, id: &str) -> bool {
        self.cancelled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(id)
    }

    pub fn mark_cancelled(&self, id: &str) {
        self.cancelled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.to_string());
    }

    pub fn clear_cancelled(&self, id: &str) {
        self.cancelled
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(id);
    }

    pub fn job_dir(&self, id: &str) -> std::path::PathBuf {
        std::path::Path::new(&self.cfg.data).join("jobs").join(id)
    }

    pub fn complete_path(&self, id: &str) -> std::path::PathBuf {
        std::path::Path::new(&self.cfg.data)
            .join("complete")
            .join(format!("{id}.mp4"))
    }

    pub fn free_bytes(&self) -> i64 {
        let p = std::path::Path::new(&self.cfg.data);
        let c = match std::ffi::CString::new(p.as_os_str().as_encoded_bytes()) {
            Ok(c) => c,
            Err(_) => return 0,
        };
        unsafe {
            let mut st: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c.as_ptr(), &mut st) == 0 {
                (st.f_bavail as i64).saturating_mul(st.f_frsize as i64)
            } else {
                0
            }
        }
    }
}
