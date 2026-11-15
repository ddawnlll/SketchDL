#!/usr/bin/env python3
"""Benchmark yt-dlp concurrent fragments on a latency-controlled HLS source.

Generates a local HLS VOD, serves it with a per-request delay, and downloads
it with `-N 1,2,4,8`. This isolates segmented-download concurrency from
YouTube and from the VPS->browser hop. It is a controlled sensitivity test,
not a promise that YouTube will behave the same way.

    python3 scripts/bench_fragments.py --delay-ms 100 --runs 2
    python3 scripts/bench_fragments.py --concurrency 1,2,4,8
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


class DelayHandler(http.server.SimpleHTTPRequestHandler):
    delay = 0.0

    def log_message(self, *args):
        pass

    def do_GET(self):
        time.sleep(self.delay)
        super().do_GET()

    def do_HEAD(self):
        time.sleep(self.delay)
        super().do_HEAD()


class QuietServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def make_hls(tmp, seconds):
    m3u8 = os.path.join(tmp, "playlist.m3u8")
    subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error",
         "-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=30:duration={seconds}",
         "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
         "-c:v", "libx264", "-preset", "veryfast", "-b:v", "1M",
         "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
         "-f", "hls", "-hls_time", "1", "-hls_list_size", "0",
         "-hls_segment_filename", os.path.join(tmp, "seg%04d.ts"), m3u8],
        check=True, capture_output=True, timeout=180)
    return m3u8


def run_one(url, concurrency, workdir, timeout=300):
    os.makedirs(workdir, exist_ok=True)
    cmd = [YTDLP, "--ignore-config", "--no-warnings", "--no-playlist",
           "--newline", "-N", str(concurrency),
           "-o", os.path.join(workdir, "%(id)s.%(ext)s"), url]
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return {"seconds": round(time.monotonic() - t0, 3),
            "exit": r.returncode,
            "stderr_tail": r.stderr[-200:] if r.returncode else ""}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delay-ms", type=int, default=100)
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--concurrency", default="1,2,4,8")
    ap.add_argument("--out", default=os.path.join(ROOT, "reports", "fragments-bench.json"))
    args = ap.parse_args()
    if not os.access(FFMPEG, os.X_OK) or not os.access(YTDLP, os.X_OK):
        print("SKIP: tools/ffmpeg or tools/yt-dlp missing", file=sys.stderr)
        return 77

    tmp = tempfile.mkdtemp(prefix="skdl-frag-")
    srv = None
    try:
        m3u8 = make_hls(tmp, args.seconds)
        size = sum(os.path.getsize(os.path.join(tmp, n))
                   for n in os.listdir(tmp) if n.endswith(".ts"))
        DelayHandler.delay = args.delay_ms / 1000.0
        handler = functools.partial(DelayHandler, directory=tmp)
        srv = QuietServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{srv.server_port}/playlist.m3u8"

        results = {}
        for n in [int(x) for x in args.concurrency.split(",") if x.strip()]:
            runs = []
            for i in range(args.runs):
                work = os.path.join(tmp, f"n{n}-{i}")
                runs.append(run_one(url, n, work))
            ok = [r["seconds"] for r in runs if r["exit"] == 0]
            results[str(n)] = {
                "runs": runs,
                "median_seconds": round(statistics.median(ok), 3) if ok else None,
                "median_bytes_per_sec": round(size / statistics.median(ok), 1) if ok else None,
                "failures": sum(1 for r in runs if r["exit"] != 0),
            }
        report = {
            "source_bytes": size,
            "source": "generated HLS, 640x360, 1s segments",
            "per_request_delay_ms": args.delay_ms,
            "results": results,
            "note": "Controlled latency sensitivity test. Keeps the app "
                    "default at -N 1 unless a real source shows a gain.",
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
