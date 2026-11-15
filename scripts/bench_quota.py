#!/usr/bin/env python3
"""A/B systemd CPUQuota on the SketchDL download workload.

Runs the same local control workload with CPUQuota=50%, CPUQuota=100% and no
explicit quota, using `systemd-run --user --scope` (cgroup v2). Two paths are
measured separately:

  download : yt-dlp fetching a generated local MP4 over loopback
  remux    : ffmpeg stream-copying the same file (merge/postprocess proxy)

This isolates CPU quota from YouTube and from the VPS->browser hop. It does
not execute EJS; a live YouTube run under quota is still the only way to
measure PO-token minting CPU.

    python3 scripts/bench_quota.py --runs 2
    python3 scripts/bench_quota.py --out reports/quota-bench.json
"""
import argparse
import functools
import http.server
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
FFMPEG = os.path.join(TOOLS, "ffmpeg-master-latest-linux64-gpl", "bin", "ffmpeg")
YTDLP = os.path.join(TOOLS, "yt-dlp")


class QuietServer(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def have_systemd_run():
    r = subprocess.run(["systemd-run", "--user", "--scope", "--quiet",
                        "--", "/bin/true"], capture_output=True, timeout=15)
    return r.returncode == 0


def quota_prefix(quota):
    if quota == "none":
        return []
    return ["systemd-run", "--user", "--scope", "--quiet",
            "-p", f"CPUQuota={quota}", "--"]


def make_source(tmp):
    path = os.path.join(tmp, "control.mp4")
    subprocess.run(
        [FFMPEG, "-y", "-f", "lavfi",
         "-i", "testsrc2=size=1280x720:rate=30:duration=20",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
         "-c:v", "libx264", "-preset", "veryfast", "-b:v", "8M",
         "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path],
        check=True, capture_output=True, timeout=180)
    return path


def timed(cmd):
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, timeout=300)
    return time.monotonic() - t0, r.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--quotas", default="50%,100%,none")
    ap.add_argument("--out", default=os.path.join(ROOT, "reports", "quota-bench.json"))
    args = ap.parse_args()
    if not os.access(FFMPEG, os.X_OK) or not os.access(YTDLP, os.X_OK):
        print("SKIP: tools/ffmpeg or tools/yt-dlp missing", file=sys.stderr)
        return 77
    if not have_systemd_run():
        print("SKIP: systemd-run --user --scope unavailable", file=sys.stderr)
        return 77

    tmp = tempfile.mkdtemp(prefix="skdl-quota-")
    srv = None
    try:
        src = make_source(tmp)
        size = os.path.getsize(src)
        handler = functools.partial(QuietHandler, directory=tmp)
        srv = QuietServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_port}/control.mp4"

        results = {}
        for quota in [q.strip() for q in args.quotas.split(",") if q.strip()]:
            dl, remux = [], []
            for i in range(args.runs):
                outdir = os.path.join(tmp, f"ytdl-{quota}-{i}")
                os.makedirs(outdir, exist_ok=True)
                cmd = quota_prefix(quota) + [
                    YTDLP, "--ignore-config", "--no-warnings", "--no-playlist",
                    "--newline", "--progress", "--progress-delta", "1",
                    "-o", "%(id)s.%(ext)s", url]
                dt, rc = timed(cmd)
                dl.append({"seconds": round(dt, 3), "exit": rc})
                outfile = os.path.join(tmp, f"remux-{quota}-{i}.mp4")
                cmd2 = quota_prefix(quota) + [
                    FFMPEG, "-y", "-loglevel", "error", "-i", src,
                    "-c", "copy", outfile]
                dt2, rc2 = timed(cmd2)
                remux.append({"seconds": round(dt2, 3), "exit": rc2})
            results[quota] = {
                "download": {
                    "runs": dl,
                    "median_seconds": round(statistics.median(d["seconds"] for d in dl), 3),
                    "median_bytes_per_sec": round(size / statistics.median(d["seconds"] for d in dl), 1),
                },
                "remux": {
                    "runs": remux,
                    "median_seconds": round(statistics.median(d["seconds"] for d in remux), 3),
                },
            }
        report = {
            "source_bytes": size,
            "source": "generated 20s 720p h264/aac over loopback",
            "host": os.uname().nodename,
            "method": "systemd-run --user --scope CPUQuota",
            "results": results,
            "caveats": "Local loopback is not YouTube. EJS/PO-token CPU is "
                       "not exercised; this isolates transfer and remux.",
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=2)
        print(json.dumps(report, indent=2))
        return 0
    finally:
        if srv is not None:
            srv.shutdown()
            srv.server_close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
