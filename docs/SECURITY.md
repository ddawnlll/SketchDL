# SketchDL — Security Model

SketchDL is a private, single-owner downloader. Threat model and boundaries.

## Trust boundaries

```
Browser (untrusted, no JS) --HTTPS--> Nginx (TLS, limits)
                                     `--> SketchDL (127.0.0.1:8087, Goose)
                                           |-- auth / sessions / CSRF
                                           |-- strict URL parser (input.goose)
                                           |-- SSR UI (views.goose, escaped)
                                           |-- SQLite (metadata only)
                                           |-- job supervisor (main thread)
                                           `-- worker-once child per job
                                                  |-- yt-dlp (fixed argv)
                                                  |-- Deno (EJS challenges)
                                                  `-- ffmpeg / ffprobe
```

- The browser is untrusted. All HTML it sees is server-rendered and escaped.
- The media extractor (yt-dlp) is a separate security boundary. It may run
  Deno for YouTube challenge solving; that is the only JavaScript in the
  system, and it is never delivered to or executed by the browser.
- Extractor output (JSON metadata, progress lines, stderr) is treated as
  hostile: parsed field-by-field, never rendered raw, never used as paths,
  URLs, shell strings, or HTML.

## Invariants

1. Zero application JavaScript: no `<script>`, no inline handlers, no
   JS frameworks. Tests assert absence on every page.
2. No arbitrary URLs: `input.goose` accepts only `https://` YouTube video
   URLs (youtube.com / youtu.be, watch/shorts/embed/live), extracts an
   11-character `[A-Za-z0-9_-]` id, and rebuilds the canonical watch URL.
   Raw input is never forwarded to yt-dlp.
3. No shell: subprocesses spawn with structured argv (proc.goose /
   vendor/proc.c). Nothing is interpolated into `sh -c`. The format spec
   (`-f`) is picked server-side from a stored inspection allowlist and
   re-validated character-by-character; presets are a fixed enum.
4. Filesystem isolation: job ids are 16 random bytes (hex); paths are
   built from templates; the post-download path must equal the expected
   `<job_dir>/<video_id>.mp4` exactly; publication is an atomic rename
   within one filesystem; `.part` files are never published.
5. Auth: single owner, Argon2id (t=2, m=19456, p=1), server-side sessions
   (SHA-256 of a 256-bit token in SQLite), `__Host-` Secure HttpOnly
   SameSite=Lax cookies, CSRF on every POST, in-process login limiter
   (5 failures / 15 min window, max 2 concurrent verifies in a dedicated
   worker), loopback bind with an explicit non-loopback flag.
6. Output hardening: `Content-Security-Policy: default-src 'none';
   style-src 'self'; img-src 'none'; font-src 'self'; form-action 'self';
   base-uri 'none'; frame-ancestors 'none'`, `X-Content-Type-Options:
   nosniff`, `Referrer-Policy: no-referrer`. Videos are served as
   `attachment` with a server-generated filename.
7. Quotas: bounded request heads (16 KiB) and bodies (64 KiB), bounded
   metadata JSON (4 MiB), bounded stderr capture, inspect deadline (60 s),
   download deadline (30 min), queue cap (`--max-active`, default 5),
   size cap (`--max-download-bytes`, default 2 GiB, enforced by yt-dlp's
   `--max-download-size` and re-checked after publish), duration cap
   (`--max-duration`, default 4 h), disk floor (`--min-free-bytes`).
8. Process group kill: extractor children run in their own sessions, so
   cancel/timeout kills yt-dlp plus Deno/FFmpeg together
   (`killpg`). Workers transition conditionally (`WHERE state = …`), so
   a restarted server never resurrects cancelled work and a stale worker
   can never overwrite a terminal state.
9. No cookies, no credentials: SketchDL never stores YouTube cookies,
   OAuth tokens, or user credentials. Private/age-restricted videos fail
   with a clear code instead of prompting for bypass.
10. No DRM, no CAPTCHA/bot bypass, no playlist/channel scraping, no
    arbitrary-site extraction. Bot-check blocks (common on datacenter
    IPs) are reported as `BOT_CHECK`, not worked around.

## Data handling

- SQLite stores metadata only (jobs, inspections, sessions). Video bytes
  live on disk (`<data>/complete/<job-id>.mp4`), retained 12 h by default.
- Error details are sanitized (single line, 240 chars) and shown without
  raw JSON or full stderr.
- Backups (`admin backup`) copy the SQLite file via the SQLite backup API;
  `admin integrity` runs `PRAGMA integrity_check`.

## Non-goals (v1)

Anonymous hosting, multi-user accounts, playlists, MP3/transcode,
H.264 re-encoding, client push, native wrappers.
