# SketchDL — Security Model

SketchDL is a private, single-owner downloader. Threat model and
boundaries.

## Trust boundaries

```
Browser (untrusted) --HTTPS--> Nginx (TLS, limits)
                              `--> SketchDL (127.0.0.1:8087, Rust/Axum)
                                    |-- auth / sessions / CSRF
                                    |-- strict URL parser (input.rs)
                                    |-- SSR views (views.rs, escaped)
                                    |-- SQLite (metadata only)
                                    `-- Tokio job task
                                          |-- yt-dlp (fixed argv)
                                          |-- Deno (EJS challenges)
                                          `-- ffmpeg / ffprobe
```

- The browser is untrusted. All HTML it sees is server-rendered and
  escaped. The only script is `/assets/progress.js`, served from the
  app with `script-src 'self'`, and it only talks to the same-origin SSE
  endpoint.
- The media extractor (yt-dlp) is a separate security boundary. It may
  run Deno for YouTube challenge solving; that is the only JavaScript
  executed by the system, never delivered to the browser.
- Extractor output (JSON metadata, progress lines, stderr) is treated as
  hostile: parsed field-by-field, never rendered raw, never used as
  paths, URLs, shell strings, or HTML.

## Invariants

1. **No untrusted client code.** Pages other than an active job page load
   no JavaScript at all. The active job page loads one static 2.8 KB
   script, with no inline handlers and no third-party origins. The CSP is
   `default-src 'none'; style-src 'self'; script-src 'self'; img-src
   'none'; font-src 'self'; connect-src 'self'; form-action 'self';
   base-uri 'none'; frame-ancestors 'none'`.
2. **No arbitrary URLs.** `input.rs` accepts only `https://` YouTube
   video URLs (youtube.com / youtu.be, watch/shorts/embed), extracts an
   11-character `[A-Za-z0-9_-]` id, and rebuilds the canonical watch URL.
   Raw input is never forwarded to yt-dlp.
3. **No shell.** Subprocesses spawn with structured argv vectors. Nothing
   is interpolated into `sh -c`. The format spec (`-f`) is picked
   server-side from a stored inspection allowlist and re-validated
   character-by-character; presets are constrained to `<height>p`.
4. **Filesystem isolation.** Job ids are 16 random bytes (hex); paths are
   built from templates. The post-download path must be an absolute path
   inside the job directory and end in `.mp4`; publication is an atomic
   rename within one filesystem. `.part` files are never published.
5. **Auth.** Single owner, Argon2id (default RustCrypto parameters,
   PHC string), server-side sessions (SHA-256 of a 256-bit token in
   SQLite), `__Host-` Secure HttpOnly SameSite=Lax cookies in production,
   CSRF on every POST, in-process login limiter (5 failures / 15 min per
   IP). The listener is loopback in the shipped unit.
6. **Output hardening.** `X-Content-Type-Options: nosniff`,
   `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, and the CSP
   above on every HTML response. Videos are served as `attachment` with a
   server-generated filename and `Cache-Control: private, no-store`.
7. **Quotas.** Bounded metadata JSON (4 MiB), bounded stderr capture
   (16 KiB newest-tail), inspect deadline (60 s), download deadline
   (30 min), concurrent job cap (`--max-active`, default 5), size cap
   (`--max-download-bytes`, 2 GiB, passed to yt-dlp and re-checked before
   publish), duration cap (`--max-duration`, 4 h), disk floor
   (`--min-free-bytes`).
8. **Process group kill.** Each yt-dlp child calls `setsid()` before
   `exec`, so cancel/timeout does `kill(-pid, SIGKILL)` and also stops
   Deno/FFmpeg descendants. Conditional SQL transitions (`WHERE state =
   …`) mean a stale event cannot overwrite a terminal state.
9. **No cookies, no credentials.** SketchDL never stores YouTube cookies,
   OAuth tokens, or user credentials. Private/age-restricted videos fail
   with a clear code instead of prompting for bypass.
10. **No DRM, no CAPTCHA/bot bypass, no playlist/channel scraping, no
    arbitrary-site extraction.** Bot-check blocks (common on datacenter
    IPs) are reported as `BOT_CHECK`, not worked around.

## Data handling

- SQLite stores metadata only (jobs, inspections, sessions). Video bytes
  live on disk (`<data>/complete/<job-id>.mp4`), retained 12 h by
  default.
- Error details are sanitized (single line, 240 chars) and shown without
  raw JSON or full stderr.
- Backups (`admin backup`) use `VACUUM INTO`; `admin integrity` runs
  `PRAGMA integrity_check`.
- Session tokens are stored as SHA-256 hashes. CSRF tokens are compared
  in constant time.

## Non-goals (v1)

Anonymous hosting, multi-user accounts, playlists, MP3/transcode, H.264
re-encoding, client push, native wrappers.
