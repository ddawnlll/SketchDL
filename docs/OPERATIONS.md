# SketchDL — Operations

## Requirements (Debian 13)

Build-time:
- Goose compiler from source (`https://github.com/aardappel/goose`;
  `make` produces `build/goose`), gcc, cmake, git. See
  `goose toolchain` for the exact expectations.
- `libargon2-dev` (links `libargon2.so.1` at runtime).

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
make build                       # produces ./sketchdl
sudo useradd --system --home /nonexistent --shell /usr/sbin/nologin sketchdl
sudo mkdir -p /var/lib/sketchdl && sudo chown sketchdl:sketchdl /var/lib/sketchdl
sudo cp sketchdl /opt/sketchdl/   # (already there after build)
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
| `--listen` | `127.0.0.1:8087` | loopback enforced |
| `--retain-hours` | `12` | file expiry |
| `--max-download-bytes` | `2147483648` | per-file cap (2 GiB) |
| `--max-duration` | `14400` | per-video cap (4 h) |
| `--max-active` | `5` | queued+running cap |
| `--min-free-bytes` | `21474836480` | disk floor (20 GiB) |
| `--inspect-timeout` | `60` (s) | metadata deadline |
| `--download-timeout` | `1800` (s) | per-download deadline |
| `--insecure-cookies` | off | for plain-HTTP testing only |
| `--trust-proxy` | off | see `X-Real-IP` limiter key |

## Backup / restore / integrity

```sh
./sketchdl admin backup --db /var/lib/sketchdl/sketchdl.db --out /backups/sketchdl-$(date +%F).db
./sketchdl admin integrity --db /var/lib/sketchdl/sketchdl.db
```

Backups use the SQLite backup API, so a hot backup while running is fine.
Complete files are NOT in the backup: restore them from the filesystem copy
(`/var/lib/sketchdl/complete/`) or accept READY rows pointing at missing
files (those fail cleanly on next access).

## Restart recovery

If the server is killed mid-download, on the next start interrupted jobs
are reset to QUEUED (up to 3 retries): leftover extractor process groups
recorded in the DB are SIGKILLed first. Conditional transitions guarantee
a stale worker cannot overwrite a cancelled/failed state.

## Troubleshooting

- `BOT_CHECK` errors: YouTube bot-detection (common on datacenter IPs).
  Nothing to fix in SketchDL; it never bypasses this.
- `FORMAT_UNAVAILABLE`: no H.264/AAC MP4 at the requested quality.
- Stuck QUEUED: the supervisor spawns within ~0.5 s; check the service
  journal and that `--ytdlp` points at an executable.
- Slow logins: Argon2id is intentionally ~1 s; the limiter allows 5
  failures per 15 min per IP.
