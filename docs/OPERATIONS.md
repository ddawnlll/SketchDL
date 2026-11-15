# SketchDL — Operations

## Requirements (Debian 13)

Build-time:
- Rust 1.85+ (edition 2024; tested with 1.99), `cargo`, a C compiler,
  `pkg-config` (SQLite is built from the bundled amalgamation).
- No Goose, Node, or WASM toolchain.

Runtime:
- `yt-dlp` — official standalone, pinned (dev: 2026.10.26 via
  `bash tools/fetch-tools.sh`; production: `curl` the release asset to
  `/usr/local/bin/yt-dlp`, `chmod +x`).
- `yt-dlp-ejs` — challenge scripts, unpacked wheel to
  `/usr/local/lib/sketchdl-ejs` and `--ejs-parent` pointing at it
  (dev: 0.8.0, same script). The bgutil WebPO plugin wheel unpacks into
  the same directory.
- `bgutil-ytdlp-pot-provider` — WebPO PO token provider (plugin, same
  unpack dir; server script sources + npm deps via `deno install` in
  `tools/bgutil-ytdlp-pot-provider/server`, dev) and `--bgutil-home`
  pointing at that `server` directory. Mints the PO token for
  datacenter-IP "Sign in to confirm you're not a bot" rejections.
- `deno >= 2.3` — single binary (dev: latest 2.x).
- `ffmpeg` + `ffprobe` — distro packages (`apt install ffmpeg`) or the
  static GPL build under `tools/`.

## Install

```sh
git clone <repo> /opt/sketchdl && cd /opt/sketchdl
make build                       # cargo build --release, copies ./sketchdl
sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin sketchdl
sudo mkdir -p /var/lib/sketchdl && sudo chown sketchdl:sketchdl /var/lib/sketchdl
sudo cp deploy/sketchdl.service /etc/systemd/system/
sudo cp deploy/nginx.conf /etc/nginx/sites-available/sketchdl
sudo ln -s /etc/nginx/sites-available/sketchdl /etc/nginx/sites-enabled/
sudo systemctl daemon-reload
sudo systemctl enable --now sketchdl
printf 'choose a strong password (12+ chars)\n' | sudo -u sketchdl /opt/sketchdl/sketchdl admin set-password --db /var/lib/sketchdl/sketchdl.db
```

Adjust `--ytdlp/--ffmpeg/--ffprobe/--deno/--ejs-parent/--bgutil-home` in
the unit to where you installed the tools.

## Configure

All knobs are command-line flags (see `--help`):

| flag | default | notes |
|---|---|---|
| `--db` | `data/sketchdl.db` | SQLite file |
| `--data` | `data` | jobs/ + complete/ dirs |
| `--listen` | `127.0.0.1:8087` | loopback in the shipped unit |
| `--retain-hours` | `12` | finished-file expiry |
| `--max-download-bytes` | `2147483648` | per-file cap (2 GiB) |
| `--max-duration` | `14400` | per-video cap (4 h) |
| `--max-active` | `5` | concurrent jobs |
| `--concurrent-fragments` | `4` | passed to yt-dlp (1–16) |
| `--min-free-bytes` | `21474836480` | disk floor (20 GiB) |
| `--inspect-timeout` | `60` (s) | metadata deadline |
| `--download-timeout` | `1800` (s) | per-download deadline |
| `--insecure-cookies` | off | plain-HTTP testing only |
| `--trust-proxy` | off | use `X-Real-IP`/`X-Forwarded-For` for the login limiter |

## Backup / restore / integrity

```sh
./sketchdl admin backup --db /var/lib/sketchdl/sketchdl.db --out /backups/sketchdl-$(date +%F).db
./sketchdl admin integrity --db /var/lib/sketchdl/sketchdl.db
```

Backups use `VACUUM INTO`, so a hot backup while running is fine.
Complete files are NOT in the backup: restore them from the filesystem
copy (`/var/lib/sketchdl/complete/`) or accept READY rows pointing at
missing files (those fail cleanly on next access).

## Restart recovery

Workers are Tokio tasks in the server process. On startup, jobs left in
`DOWNLOADING`/`VERIFYING` have their old process group (recorded in
`jobs.child_pid`) killed with `SIGKILL`, then are requeued (up to 3
attempts) and spawned again. Conditional SQL transitions (`WHERE state =
…`) mean a late event cannot overwrite a cancelled/failed job.

A `SIGKILL`ed server cannot leave an orphan writing to a job it no
longer owns: there is no separate worker process to survive the server.
Only the yt-dlp child survives briefly, and recovery kills its group.

## nginx and SSE

The bundled nginx config disables buffering for `/jobs/<id>/events`:

```nginx
location ~ ^/jobs/[0-9a-f]+/events$ {
    proxy_pass http://sketchdl_app;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 1h;
}
```

Without `proxy_buffering off`, nginx holds SSE frames and the progress
bar updates in bursts. The job page also has a 3-second meta-refresh
fallback, so a buffering proxy cannot leave it permanently stale.

## Troubleshooting

- `BOT_CHECK` errors: YouTube bot-detection (common on datacenter IPs).
  Nothing to fix in SketchDL; it never bypasses this. Check that
  `--deno`, `--ejs-parent`, and `--bgutil-home` are correct if it worked
  before.
- `TIMEOUT` on inspect: metadata took longer than `--inspect-timeout`.
  This is reported separately from `FORMAT_UNAVAILABLE`.
- `FORMAT_UNAVAILABLE`: no H.264/AAC MP4 at the requested quality.
- Stuck QUEUED: `--max-active` jobs may already be running, or the job
  is waiting for a semaphore permit. Check the journal and that
  `--ytdlp` points at an executable.
- Slow logins: Argon2id is intentionally ~1 s; the limiter allows 5
  failures per 15 min per IP.
- Downloading starts but the bar is flat: check nginx SSE buffering and
  that the browser is not blocking `EventSource`. The page's 3-second
  refresh still shows real bytes from SQLite.
