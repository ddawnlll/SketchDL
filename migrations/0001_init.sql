-- SketchDL schema v1 (SQLite 3.54.1)
-- Metadata only. Video bytes live on disk, never in SQLite.

CREATE TABLE owner (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    password_hash TEXT    NOT NULL,
    created_at    INTEGER NOT NULL
);

CREATE TABLE sessions (
    token_hash   TEXT    PRIMARY KEY,
    owner_id     INTEGER NOT NULL REFERENCES owner(id) ON DELETE CASCADE,
    csrf_token   TEXT    NOT NULL,
    issued_at    INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL,
    revoked      INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
);
CREATE INDEX sessions_expiry ON sessions(expires_at);

-- Short-lived metadata-only inspections (10 minutes). formats_json is the
-- validated allowlist the enqueue path re-checks against.
CREATE TABLE inspections (
    token_hash   TEXT    PRIMARY KEY,
    owner_id     INTEGER NOT NULL REFERENCES owner(id) ON DELETE CASCADE,
    video_id     TEXT    NOT NULL,
    title        TEXT    NOT NULL,
    duration     INTEGER,
    formats_json TEXT    NOT NULL,
    expires_at   INTEGER NOT NULL
);
CREATE INDEX inspections_expiry ON inspections(expires_at);

CREATE TABLE jobs (
    id               TEXT    PRIMARY KEY,
    owner_id         INTEGER NOT NULL REFERENCES owner(id) ON DELETE CASCADE,
    video_id         TEXT    NOT NULL,
    title            TEXT,
    preset           TEXT    NOT NULL,
    format_id        TEXT,
    state            TEXT    NOT NULL CHECK (state IN (
        'QUEUED','DOWNLOADING','VERIFYING','READY','FAILED','CANCELLED','EXPIRED'
    )),
    stage            TEXT,
    downloaded_bytes INTEGER NOT NULL DEFAULT 0,
    total_bytes      INTEGER,
    speed_bps        INTEGER,
    eta_seconds      INTEGER,
    output_bytes     INTEGER,
    worker_pid       INTEGER,
    child_pid        INTEGER,
    error_code       TEXT,
    error_detail     TEXT,
    retry_count      INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    expires_at       INTEGER,
    version          INTEGER NOT NULL DEFAULT 0 CHECK (version >= 0)
);
CREATE INDEX idx_jobs_created ON jobs(owner_id, created_at DESC);
CREATE INDEX idx_jobs_state   ON jobs(state, updated_at);

CREATE TABLE job_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT    NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    at         INTEGER NOT NULL,
    from_state TEXT,
    to_state   TEXT    NOT NULL,
    code       TEXT
);
CREATE INDEX job_events_job ON job_events(job_id, id);

-- schema_meta is created by db::migrate before this file runs.
