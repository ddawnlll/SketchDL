use crate::auth::{
    clear_cookie, cookie_name, csrf_ok, parse_cookie, random_hex, session_cookie, sha256_hex,
    valid_password_bytes, verify_password,
};
use crate::db::{Job, now};
use crate::input::{InputError, parse_youtube_url, valid_job_id};
use crate::jobs;
use crate::state::AppState;
use crate::views;
use crate::ytdlp::{Format, parse_stored_formats, select_format};
use axum::Router;
use axum::body::Body;
use axum::extract::{ConnectInfo, Form, Path, State};
use axum::http::{HeaderMap, HeaderValue, Method, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use bytes::Bytes;
use futures_util::stream;
use serde::Deserialize;
use std::convert::Infallible;
use std::io::SeekFrom;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

const CSS: &str = include_str!("../../web/style.css");
const JS: &str = include_str!("../../web/progress.js");

#[derive(Deserialize)]
struct LoginForm {
    password: String,
}

#[derive(Deserialize)]
struct InspectForm {
    url: String,
    csrf: Option<String>,
}

#[derive(Deserialize)]
struct CreateJobForm {
    inspect: String,
    preset: String,
    csrf: Option<String>,
}

#[derive(Deserialize)]
struct CsrfForm {
    csrf: Option<String>,
}

#[derive(Clone)]
struct Session {
    csrf: String,
    token_hash: String,
}

fn sec_headers(resp: &mut Response) {
    let h = resp.headers_mut();
    h.insert(
        "content-security-policy",
        HeaderValue::from_static(views::CSP),
    );
    h.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    h.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    h.insert("x-frame-options", HeaderValue::from_static("DENY"));
    h.insert("cache-control", HeaderValue::from_static("no-store"));
}

fn html(status: StatusCode, body: String) -> Response {
    let mut r = Response::new(Body::from(body));
    *r.status_mut() = status;
    r.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    sec_headers(&mut r);
    r
}

fn redirect(location: &str) -> Response {
    let mut r = Response::new(Body::empty());
    *r.status_mut() = StatusCode::SEE_OTHER;
    if let Ok(v) = HeaderValue::from_str(location) {
        r.headers_mut().insert(header::LOCATION, v);
    }
    r
}

fn with_cookie(mut r: Response, cookie: String) -> Response {
    if let Ok(v) = HeaderValue::from_str(&cookie) {
        r.headers_mut().insert(header::SET_COOKIE, v);
    }
    r
}

fn err_page(status: StatusCode, title: &str, detail: &str) -> Response {
    html(status, views::error_page(status.as_u16(), title, detail))
}

fn session(state: &AppState, headers: &HeaderMap) -> Option<Session> {
    let raw = headers.get(header::COOKIE)?.to_str().ok()?;
    let token = parse_cookie(raw, cookie_name(state.cfg.secure_cookies))?;
    let hash = sha256_hex(token.as_bytes());
    let (csrf, _) = state.db.find_session(&hash, now())?;
    Some(Session {
        csrf,
        token_hash: hash,
    })
}

fn require(state: &AppState, headers: &HeaderMap) -> Result<Session, Response> {
    session(state, headers).ok_or_else(|| redirect("/login"))
}

fn csrf_guard(s: &Session, form: &Option<String>) -> Result<(), Response> {
    if csrf_ok(&s.csrf, form.as_deref().unwrap_or("")) {
        Ok(())
    } else {
        Err(err_page(
            StatusCode::FORBIDDEN,
            "CSRF check failed",
            "Reload the page and try again.",
        ))
    }
}

fn client_ip(state: &AppState, addr: &SocketAddr, headers: &HeaderMap) -> String {
    if state.cfg.trust_proxy {
        if let Some(v) = headers.get("x-real-ip").and_then(|v| v.to_str().ok()) {
            return v.trim().to_string();
        }
        if let Some(v) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
            if let Some(first) = v.split(',').next() {
                return first.trim().to_string();
            }
        }
    }
    addr.ip().to_string()
}

async fn health() -> Response {
    let mut r = Response::new(Body::from("ok\n"));
    r.headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    r
}

async fn asset_css() -> Response {
    let mut r = Response::new(Body::from(CSS));
    r.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/css; charset=utf-8"),
    );
    r.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=31536000, immutable"),
    );
    r
}

async fn asset_js() -> Response {
    let mut r = Response::new(Body::from(JS));
    r.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/javascript; charset=utf-8"),
    );
    r.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    r
}

async fn get_login(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    if session(&state, &headers).is_some() {
        return redirect("/");
    }
    if !state.db.has_owner() {
        return html(
            StatusCode::SERVICE_UNAVAILABLE,
            views::login_page(Some(
                "No owner password is set. Run: sketchdl admin set-password --db <path>",
            )),
        );
    }
    html(StatusCode::OK, views::login_page(None))
}

async fn post_login(
    State(state): State<Arc<AppState>>,
    ConnectInfo(ci): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Form(form): Form<LoginForm>,
) -> Response {
    let ip = client_ip(&state, &ci, &headers);
    if state.limiter.blocked(&ip) {
        return err_page(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many attempts",
            "Wait a few minutes before trying again.",
        );
    }
    let Some(hash) = state.db.owner_hash() else {
        return html(
            StatusCode::SERVICE_UNAVAILABLE,
            views::login_page(Some("No owner password is set on this server.")),
        );
    };
    if !valid_password_bytes(&form.password) || !verify_password(&hash, &form.password) {
        state.limiter.fail(&ip);
        return html(
            StatusCode::UNAUTHORIZED,
            views::login_page(Some("Wrong password. Try again.")),
        );
    }
    state.limiter.success(&ip);
    if let Some(old) = session(&state, &headers) {
        state.db.revoke_session(&old.token_hash);
    }
    let token = random_hex(32);
    let token_hash = sha256_hex(token.as_bytes());
    let csrf = random_hex(32);
    let max_age = state.cfg.session_days.max(1) * 86_400;
    let t = now();
    if state
        .db
        .create_session(&token_hash, &csrf, t, t + max_age)
        .is_err()
    {
        return err_page(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not start a session",
            "The database rejected the session.",
        );
    }
    with_cookie(
        redirect("/"),
        session_cookie(&token, max_age, state.cfg.secure_cookies),
    )
}

async fn post_logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<CsrfForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    state.db.revoke_session(&s.token_hash);
    with_cookie(redirect("/login"), clear_cookie(state.cfg.secure_cookies))
}

async fn get_home(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let jobs = state.db.list_jobs(8);
    html(StatusCode::OK, views::home_page(&s.csrf, &jobs, None))
}

fn validate_token(token: &str) -> bool {
    token.len() == 64
        && token
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

async fn post_inspect(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<InspectForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    let (video_id, canonical) = match parse_youtube_url(form.url.trim()) {
        Ok(v) => v,
        Err(InputError::BadHost) => {
            return html(
                StatusCode::OK,
                views::home_page(
                    &s.csrf,
                    &state.db.list_jobs(8),
                    Some("Only https youtube.com / youtu.be video links are accepted here."),
                ),
            );
        }
        Err(InputError::BadId) => {
            return html(
                StatusCode::OK,
                views::home_page(
                    &s.csrf,
                    &state.db.list_jobs(8),
                    Some("That YouTube video id is not valid."),
                ),
            );
        }
    };
    let insp = match jobs::inspect_video(&state, &video_id, &canonical).await {
        Ok(i) => i,
        Err((code, detail)) => {
            return html(
                StatusCode::OK,
                views::inspect_error(&s.csrf, &code, &detail),
            );
        }
    };
    if let Some(d) = insp.duration {
        if d > state.cfg.max_duration {
            return html(
                StatusCode::OK,
                views::inspect_error(
                    &s.csrf,
                    "TOO_LONG",
                    "This video is longer than the configured limit.",
                ),
            );
        }
    }
    if select_format(&insp.formats, 4320).is_none() {
        return html(
            StatusCode::OK,
            views::inspect_empty(
                &s.csrf,
                "This video has no H.264/AAC MP4 formats that SketchDL can produce.",
            ),
        );
    }
    let token = random_hex(32);
    let token_hash = sha256_hex(token.as_bytes());
    let formats_json = crate::ytdlp::formats_to_json(&insp.formats);
    let expires = now() + 600;
    if state
        .db
        .store_inspection(
            &token_hash,
            &insp.id,
            &insp.title,
            insp.duration,
            &formats_json,
            expires,
        )
        .is_err()
    {
        return err_page(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not store the preview",
            "The database rejected the inspection.",
        );
    }
    redirect(&format!("/inspect/{token}"))
}

async fn get_inspect(
    State(state): State<Arc<AppState>>,
    Path(token): Path<String>,
    headers: HeaderMap,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if !validate_token(&token) {
        return err_page(
            StatusCode::NOT_FOUND,
            "Preview not found",
            "This preview link is invalid.",
        );
    }
    let hash = sha256_hex(token.as_bytes());
    let Some(insp) = state.db.find_inspection(&hash, now()) else {
        return err_page(
            StatusCode::GONE,
            "Preview expired",
            "Inspect the video again from the home page.",
        );
    };
    let formats = parse_stored_formats(&insp.formats_json);
    if formats.is_empty() {
        return err_page(
            StatusCode::GONE,
            "Preview empty",
            "Inspect the video again from the home page.",
        );
    }
    html(
        StatusCode::OK,
        views::inspect_page(
            &s.csrf,
            &token,
            &insp.title,
            insp.duration,
            &formats,
            &insp.video_id,
        ),
    )
}

fn preset_ceiling(preset: &str) -> Option<i64> {
    let n = preset.strip_suffix('p')?;
    if !(3..=4).contains(&n.len()) || !n.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let v: i64 = n.parse().ok()?;
    if (144..=4320).contains(&v) {
        Some(v)
    } else {
        None
    }
}

async fn post_create_job(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Form(form): Form<CreateJobForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    if !validate_token(&form.inspect) {
        return err_page(
            StatusCode::BAD_REQUEST,
            "Preview not found",
            "Inspect the video again from the home page.",
        );
    }
    let Some(ceiling) = preset_ceiling(&form.preset) else {
        return err_page(
            StatusCode::BAD_REQUEST,
            "Invalid quality",
            "Choose one of the listed qualities.",
        );
    };
    let hash = sha256_hex(form.inspect.as_bytes());
    let Some(insp) = state.db.find_inspection(&hash, now()) else {
        return err_page(
            StatusCode::GONE,
            "Preview expired",
            "Inspect the video again from the home page.",
        );
    };
    let formats: Vec<Format> = parse_stored_formats(&insp.formats_json);
    let Some((spec, _est)) = select_format(&formats, ceiling) else {
        return err_page(
            StatusCode::BAD_REQUEST,
            "FORMAT_UNAVAILABLE",
            "No MP4-compatible format is available at that quality.",
        );
    };
    let id = random_hex(16);
    let title = if insp.title.is_empty() {
        insp.video_id.clone()
    } else {
        insp.title.clone()
    };
    if state
        .db
        .create_job(&id, &insp.video_id, &title, &form.preset, &spec, now())
        .is_err()
    {
        return err_page(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Could not create the job",
            "The database rejected the job.",
        );
    }
    state.db.delete_inspection(&hash);
    jobs::spawn_job(state.clone(), id.clone());
    redirect(&format!("/jobs/{id}"))
}

async fn get_jobs(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    let jobs = state.db.list_jobs(100);
    html(StatusCode::OK, views::jobs_page(&s.csrf, &jobs))
}

fn get_job_or_404(state: &AppState, id: &str) -> Result<Job, Response> {
    if !valid_job_id(id) {
        return Err(err_page(
            StatusCode::NOT_FOUND,
            "Job not found",
            "That job id is not valid.",
        ));
    }
    state.db.find_job(id).ok_or_else(|| {
        err_page(
            StatusCode::NOT_FOUND,
            "Job not found",
            "That download does not exist.",
        )
    })
}

async fn get_job(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    match get_job_or_404(&state, &id) {
        Ok(job) => html(StatusCode::OK, views::job_page(&s.csrf, &job, None)),
        Err(r) => r,
    }
}

async fn post_cancel(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<CsrfForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    let job = match get_job_or_404(&state, &id) {
        Ok(j) => j,
        Err(r) => return r,
    };
    if matches!(job.state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING") {
        state.mark_cancelled(&id);
        state.db.cancel(&id, now());
        if let Some(pid) = job.child_pid {
            if pid > 0 {
                crate::proc::kill_group(pid as u32);
            }
        }
        let _ = std::fs::remove_dir_all(state.job_dir(&id));
        state.publish_current(&id);
    }
    redirect(&format!("/jobs/{id}"))
}

async fn post_retry(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<CsrfForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    let job = match get_job_or_404(&state, &id) {
        Ok(j) => j,
        Err(r) => return r,
    };
    if matches!(job.state.as_str(), "FAILED" | "CANCELLED") && job.retry_count < 3 {
        state.clear_cancelled(&id);
        if state.db.requeue(&id, now(), "RETRY") {
            state.publish_current(&id);
            jobs::spawn_job(state.clone(), id.clone());
        }
    }
    redirect(&format!("/jobs/{id}"))
}

async fn post_delete(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<CsrfForm>,
) -> Response {
    let s = match require(&state, &headers) {
        Ok(s) => s,
        Err(r) => return r,
    };
    if let Err(r) = csrf_guard(&s, &form.csrf) {
        return r;
    }
    let job = match get_job_or_404(&state, &id) {
        Ok(j) => j,
        Err(r) => return r,
    };
    if matches!(job.state.as_str(), "QUEUED" | "DOWNLOADING" | "VERIFYING") {
        return err_page(
            StatusCode::CONFLICT,
            "Job is still running",
            "Cancel it before removing it.",
        );
    }
    let _ = std::fs::remove_file(state.complete_path(&id));
    let _ = std::fs::remove_dir_all(state.job_dir(&id));
    state.db.delete_job(&id);
    state.events.close(&id);
    redirect("/jobs")
}

fn terminal_json(msg: &str) -> bool {
    msg.contains("\"state\":\"READY\"")
        || msg.contains("\"state\":\"FAILED\"")
        || msg.contains("\"state\":\"CANCELLED\"")
        || msg.contains("\"state\":\"EXPIRED\"")
}

struct SseState {
    rx: tokio::sync::broadcast::Receiver<String>,
    initial: Option<String>,
    terminal: bool,
}

async fn get_events(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    if require(&state, &headers).is_err() {
        return redirect("/login");
    }
    let job = match get_job_or_404(&state, &id) {
        Ok(j) => j,
        Err(r) => return r,
    };
    let initial = views::sse_progress(&job);
    let rx = state.events.channel(&id);
    let st = SseState {
        rx,
        initial: Some(initial),
        terminal: false,
    };
    let stream = stream::unfold(st, move |mut s: SseState| async move {
        if s.terminal {
            return None;
        }
        if let Some(msg) = s.initial.take() {
            s.terminal = terminal_json(&msg);
            return Some((
                Ok::<Bytes, Infallible>(Bytes::from(format!("data: {msg}\n\n"))),
                s,
            ));
        }
        loop {
            tokio::select! {
                r = s.rx.recv() => {
                    match r {
                        Ok(msg) => {
                            s.terminal = terminal_json(&msg);
                            return Some((
                                Ok::<Bytes, Infallible>(Bytes::from(format!("data: {msg}\n\n"))),
                                s,
                            ));
                        }
                        Err(_) => return None,
                    }
                }
                _ = tokio::time::sleep(Duration::from_secs(15)) => {
                    return Some((
                        Ok::<Bytes, Infallible>(Bytes::from_static(b": keep-alive\n\n")),
                        s,
                    ));
                }
            }
        }
    });
    let mut r = Response::new(Body::from_stream(stream));
    r.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/event-stream"),
    );
    r.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    r.headers_mut()
        .insert("x-accel-buffering", HeaderValue::from_static("no"));
    r
}

async fn get_download(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    if require(&state, &headers).is_err() {
        return redirect("/login");
    }
    let job = match get_job_or_404(&state, &id) {
        Ok(j) => j,
        Err(r) => return r,
    };
    if job.state != "READY" {
        return err_page(
            StatusCode::CONFLICT,
            "Not ready",
            "This download is not ready yet.",
        );
    }
    let path = state.complete_path(&id);
    let meta = match tokio::fs::metadata(&path).await {
        Ok(m) if m.is_file() && m.len() > 0 => m,
        _ => {
            return err_page(
                StatusCode::GONE,
                "File missing",
                "The finished file is no longer on disk.",
            );
        }
    };
    let total = meta.len();
    let etag = format!("\"{}-{}\"", job.id, total);
    if headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v == etag)
    {
        let mut r = Response::new(Body::empty());
        *r.status_mut() = StatusCode::NOT_MODIFIED;
        r.headers_mut()
            .insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
        return r;
    }
    let disposition = format!("attachment; filename=\"{}.mp4\"", job.video_id);
    let mut range: Option<(u64, u64)> = None;
    if let Some(raw) = headers.get(header::RANGE).and_then(|v| v.to_str().ok()) {
        let raw = raw.trim();
        if let Some(spec) = raw.strip_prefix("bytes=") {
            if spec.contains(',') {
                return range_416(total);
            }
            let Some((a, b)) = spec.split_once('-') else {
                return range_416(total);
            };
            if a.is_empty() {
                match b.parse::<u64>() {
                    Ok(0) => return range_416(total),
                    Ok(n) => {
                        let n = n.min(total);
                        range = Some((total - n, total - 1));
                    }
                    Err(_) => return range_416(total),
                }
            } else {
                let start = match a.parse::<u64>() {
                    Ok(v) => v,
                    Err(_) => return range_416(total),
                };
                if start >= total {
                    return range_416(total);
                }
                let end = if b.is_empty() {
                    total - 1
                } else {
                    match b.parse::<u64>() {
                        Ok(v) => v.min(total - 1),
                        Err(_) => return range_416(total),
                    }
                };
                if end < start {
                    return range_416(total);
                }
                range = Some((start, end));
            }
        } else {
            return range_416(total);
        }
    }

    match range {
        Some((start, end)) => {
            let len = end - start + 1;
            let mut f = match tokio::fs::File::open(&path).await {
                Ok(f) => f,
                Err(_) => {
                    return err_page(StatusCode::GONE, "File missing", "Could not open the file.");
                }
            };
            if f.seek(SeekFrom::Start(start)).await.is_err() {
                return err_page(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Seek failed",
                    "Could not seek in the finished file.",
                );
            }
            let body = Body::from_stream(ReaderStream::new(f.take(len)));
            let mut r = Response::new(body);
            *r.status_mut() = StatusCode::PARTIAL_CONTENT;
            let h = r.headers_mut();
            h.insert(header::CONTENT_TYPE, HeaderValue::from_static("video/mp4"));
            h.insert(
                header::CONTENT_LENGTH,
                HeaderValue::from_str(&len.to_string()).unwrap(),
            );
            h.insert(
                header::CONTENT_RANGE,
                HeaderValue::from_str(&format!("bytes {start}-{end}/{total}")).unwrap(),
            );
            h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
            h.insert(
                header::CONTENT_DISPOSITION,
                HeaderValue::from_str(&disposition).unwrap(),
            );
            h.insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
            h.insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("private, no-store"),
            );
            r
        }
        None => {
            let f = match tokio::fs::File::open(&path).await {
                Ok(f) => f,
                Err(_) => {
                    return err_page(StatusCode::GONE, "File missing", "Could not open the file.");
                }
            };
            let body = Body::from_stream(ReaderStream::new(f));
            let mut r = Response::new(body);
            let h = r.headers_mut();
            h.insert(header::CONTENT_TYPE, HeaderValue::from_static("video/mp4"));
            h.insert(
                header::CONTENT_LENGTH,
                HeaderValue::from_str(&total.to_string()).unwrap(),
            );
            h.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
            h.insert(
                header::CONTENT_DISPOSITION,
                HeaderValue::from_str(&disposition).unwrap(),
            );
            h.insert(header::ETAG, HeaderValue::from_str(&etag).unwrap());
            h.insert(
                header::CACHE_CONTROL,
                HeaderValue::from_static("private, no-store"),
            );
            r
        }
    }
}

fn range_416(total: u64) -> Response {
    let mut r = Response::new(Body::empty());
    *r.status_mut() = StatusCode::RANGE_NOT_SATISFIABLE;
    r.headers_mut().insert(
        header::CONTENT_RANGE,
        HeaderValue::from_str(&format!("bytes */{total}")).unwrap(),
    );
    r
}

async fn fallback(
    method: Method,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Response {
    if matches!(method, Method::GET | Method::HEAD) {
        if session(&state, &headers).is_none() {
            return redirect("/login");
        }
        return err_page(
            StatusCode::NOT_FOUND,
            "Page not found",
            "That page does not exist.",
        );
    }
    err_page(
        StatusCode::METHOD_NOT_ALLOWED,
        "Method not allowed",
        "That request is not supported here.",
    )
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/", get(get_home))
        .route("/login", get(get_login).post(post_login))
        .route("/logout", post(post_logout))
        .route("/inspect", post(post_inspect))
        .route("/inspect/{token}", get(get_inspect))
        .route("/jobs", get(get_jobs).post(post_create_job))
        .route("/jobs/{id}", get(get_job))
        .route("/jobs/{id}/cancel", post(post_cancel))
        .route("/jobs/{id}/retry", post(post_retry))
        .route("/jobs/{id}/delete", post(post_delete))
        .route("/jobs/{id}/events", get(get_events))
        .route("/downloads/{id}", get(get_download))
        .route("/assets/style.css", get(asset_css))
        .route("/assets/progress.js", get(asset_js))
        .fallback(fallback)
        .with_state(state)
}

pub fn recover(state: &Arc<AppState>) {
    let t = now();
    for job in state.db.active_jobs() {
        if let Some(pid) = job.child_pid {
            if pid > 0 {
                crate::proc::kill_group(pid as u32);
            }
        }
        if job.state == "VERIFYING" || job.state == "DOWNLOADING" {
            if state.db.requeue(&job.id, t, "RESTART") {
                jobs::spawn_job(state.clone(), job.id.clone());
            } else {
                state.db.set_failure(
                    &job.id,
                    "RESTART_LIMIT",
                    "This job was interrupted too many times.",
                    t,
                );
            }
        }
    }
    for job in state.db.expired_ready(t) {
        let _ = std::fs::remove_file(state.complete_path(&job.id));
        state.db.expire_ready(&job.id, t);
    }
    state.db.delete_expired_sessions(t);
    state.db.delete_expired_inspections(t);
}

async fn janitor(state: Arc<AppState>) {
    loop {
        tokio::time::sleep(Duration::from_secs(60)).await;
        let t = now();
        for job in state.db.expired_ready(t) {
            let _ = std::fs::remove_file(state.complete_path(&job.id));
            state.db.expire_ready(&job.id, t);
        }
        state.db.delete_expired_sessions(t);
        state.db.delete_expired_inspections(t);
    }
}

pub async fn run(state: Arc<AppState>) -> Result<(), String> {
    recover(&state);
    tokio::spawn(janitor(state.clone()));
    let listener = tokio::net::TcpListener::bind(&state.cfg.listen)
        .await
        .map_err(|e| format!("bind {}: {e}", state.cfg.listen))?;
    let app = router(state);
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await
    .map_err(|e| format!("server error: {e}"))
}
