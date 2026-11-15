#!/usr/bin/env python3
"""Sanitized download diagnostics for SketchDL / yt-dlp.

Measures the YouTube-to-VPS side of the pipeline independently of the app:

  - progress bytes reported by yt-dlp itself
  - observed throughput samples derived from byte deltas over wall time
  - whole-process-tree CPU time and peak RSS
  - host network receive delta (best effort)
  - exit status, retries and sanitized error lines

It never logs cookies, tokens, signed media URLs, request headers or query
strings. The output contains only scheme + host category for the source.

Reproducible control run (no network):

    python3 scripts/diagnose.py --runs 3

Live run against an authorized/test asset:

    python3 scripts/diagnose.py --url 'https://www.youtube.com/watch?v=...' \
        --runs 1 --out reports/diagnose-live.json

This is a measurement tool, not a speed claim. A result of "slow" only says
the bytes observed during this run were slow; it does not identify whether
YouTube, the network path, CPU quota or something else caused it.
"""
import argparse
import functools
import http.server
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
FFMPEG = os.path.join(TOOLS, "ffmpeg-master-latest-linux64-gpl", "bin", "ffmpeg")
YTDLP = os.path.join(TOOLS, "yt-dlp")

# Same wire shape the app parses. Kept literal here on purpose: the contract
# test in tests/integration.py proves the app's template renders this way.
TEMPLATE = ("download:skdl-progress|%(progress.downloaded_bytes)s|"
            "%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|"
            "%(progress.speed)s|%(progress.eta)s|"
            "%(info.format_id)s|%(info.vcodec)s|%(info.acodec)s")
MARKER = "skdl-progress|"


def sanitize_url(url):
    try:
        u = urllib.parse.urlsplit(url)
    except ValueError:
        return "invalid"
    host = u.hostname or ""
    if "youtube" in host or "youtu.be" in host:
        host = "youtube"
    elif host in ("127.0.0.1", "localhost"):
        host = "local"
    else:
        host = "other"
    return {"scheme": u.scheme, "host_category": host}


def sanitize_line(line):
    line = re.sub(r"https?://\S+", "<url>", line)
    line = re.sub(r"[A-Za-z0-9_\-]{40,}", "<token>", line)
    return line.strip()[:240]


def tree_pids(root):
    children = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as fh:
                rest = fh.read().rsplit(")", 1)[1].split()
            ppid = int(rest[1])
        except (OSError, IndexError, ValueError):
            continue
        children.setdefault(ppid, []).append(int(name))
    out, stack = [], [root]
    while stack:
        p = stack.pop()
        out.append(p)
        stack.extend(children.get(p, []))
    return out


def tree_cpu_seconds(root):
    ticks = 0
    hz = os.sysconf("SC_CLK_TCK")
    for pid in tree_pids(root):
        try:
            with open(f"/proc/{pid}/stat") as fh:
                rest = fh.read().rsplit(")", 1)[1].split()
            ticks += int(rest[11]) + int(rest[12])
        except (OSError, IndexError, ValueError):
            pass
    return ticks / hz


def tree_rss_kib(root):
    total = 0
    for pid in tree_pids(root):
        try:
            with open(f"/proc/{pid}/status") as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1])
                        break
        except (OSError, ValueError):
            pass
    return total


def net_rx_bytes():
    total = 0
    try:
        with open("/proc/net/dev") as fh:
            for line in fh.readlines()[2:]:
                name, rest = line.split(":", 1)
                if name.strip() == "lo":
                    continue
                total += int(rest.split()[0])
    except (OSError, ValueError):
        return None
    return total


class QuietServer(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def local_source(tmp, seconds, height):
    if not os.access(FFMPEG, os.X_OK):
        return None, None
    path = os.path.join(tmp, "control.mp4")
    width = (height * 16) // 9
    subprocess.run(
        [FFMPEG, "-y", "-f", "lavfi",
         "-i", f"testsrc2=size={width}x{height}:rate=30:duration={seconds}",
         "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
         "-c:v", "libx264", "-preset", "veryfast", "-b:v", "4M",
         "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", path],
        check=True, capture_output=True, timeout=120)
    handler = functools.partial(QuietHandler, directory=tmp)
    srv = QuietServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_port}/control.mp4", srv


def run_once(ytdlp, url, workdir, timeout, fmt=None, app_profile=False,
             section=None, max_bytes=64 * 1024 * 1024):
    home = os.path.join(workdir, "home")
    temp = os.path.join(workdir, "temp")
    os.makedirs(home, exist_ok=True)
    os.makedirs(temp, exist_ok=True)
    cmd = [ytdlp, "--ignore-config", "--no-warnings", "--no-playlist",
           "--newline", "--progress", "--progress-delta", "1",
           "--progress-template", TEMPLATE,
           "--paths", "home:" + home, "--paths", "temp:" + temp,
           "--socket-timeout", "15", "--retries", "3",
           "--max-filesize", str(max_bytes),
           "-o", "%(id)s.%(ext)s", url]
    env = dict(os.environ)
    if app_profile:
        ejs = os.path.join(TOOLS, "ejs")
        bgutil = os.path.join(
            TOOLS, "bgutil-ytdlp-pot-provider", "server")
        deno = os.path.join(TOOLS, "deno")
        ffmpeg_dir = os.path.join(
            TOOLS, "ffmpeg-master-latest-linux64-gpl", "bin")
        env["PYTHONPATH"] = ejs
        cmd[-1:-1] = [
            "--plugin-dirs", ejs,
            "--extractor-args",
            "youtubepot-bgutilscript:server_home=" + bgutil,
            "--extractor-args",
            "youtube:fetch_pot=always;player_client=mweb,tv,web_safari",
            "--js-runtimes", "deno:" + deno,
            "--ffmpeg-location", ffmpeg_dir,
        ]
    if fmt:
        cmd[-1:-1] = ["-f", fmt]
    if section:
        cmd[-1:-1] = ["--download-sections", section]
    t0 = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1, env=env)
    records = []
    errors = []

    def read_stdout():
        for line in proc.stdout:
            line = line.strip()
            if line.startswith(MARKER):
                parts = line[len(MARKER):].split("|")
                if len(parts) == 8:
                    try:
                        records.append({
                            "t": time.monotonic() - t0,
                            "downloaded": int(float(parts[0])),
                            "total": (int(float(parts[1])) if parts[1] not in
                                      ("NA", "None", "") else None),
                            "estimate": (int(float(parts[2])) if parts[2] not in
                                         ("NA", "None", "") else None),
                            "format_id": parts[5],
                        })
                    except ValueError:
                        pass

    def read_stderr():
        for line in proc.stderr:
            s = sanitize_line(line)
            if s:
                errors.append(s)
                if len(errors) > 20:
                    errors.pop(0)

    t_out = threading.Thread(target=read_stdout, daemon=True)
    t_err = threading.Thread(target=read_stderr, daemon=True)
    t_out.start()
    t_err.start()
    cpu0 = tree_cpu_seconds(os.getpid())
    rx0 = net_rx_bytes()
    peak_rss, peak_cpu = 0, 0.0
    timed_out = False
    try:
        while proc.poll() is None:
            peak_rss = max(peak_rss, tree_rss_kib(os.getpid()))
            peak_cpu = max(peak_cpu, tree_cpu_seconds(os.getpid()) - cpu0)
            if time.monotonic() - t0 > timeout:
                proc.kill()
                timed_out = True
                break
            time.sleep(0.25)
    finally:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        t_out.join(timeout=5)
        t_err.join(timeout=5)
    wall = time.monotonic() - t0
    cpu = max(peak_cpu, tree_cpu_seconds(os.getpid()) - cpu0)
    rx1 = net_rx_bytes()
    rx = (rx1 - rx0) if (rx0 is not None and rx1 is not None) else None

    samples = []
    for a, b in zip(records, records[1:]):
        dt = b["t"] - a["t"]
        db = b["downloaded"] - a["downloaded"]
        if dt > 0.2 and db >= 0:
            samples.append(db / dt)
    final = records[-1] if records else None
    avg = None
    if len(records) >= 2:
        dt = records[-1]["t"] - records[0]["t"]
        db = records[-1]["downloaded"] - records[0]["downloaded"]
        if dt > 0 and db > 0:
            avg = db / dt
    if avg is None and final and final["downloaded"] > 0 and wall > 0:
        avg = final["downloaded"] / wall
    result = {
        "exit_code": proc.returncode,
        "timed_out": timed_out,
        "wall_seconds": round(wall, 3),
        "progress_records": len(records),
        "time_to_first_progress_seconds": (round(records[0]["t"], 3)
                                           if records else None),
        "transfer_window_seconds": (round(records[-1]["t"] - records[0]["t"], 3)
                                    if len(records) >= 2 else None),
        "final_downloaded_bytes": final["downloaded"] if final else 0,
        "final_total_bytes": (final["total"] or final["estimate"]) if final else None,
        "format_id": final["format_id"] if final else None,
        "throughput_bytes_per_sec": {
            "median": round(statistics.median(samples), 1) if samples else None,
            "p10": round(sorted(samples)[len(samples) // 10], 1) if samples else None,
            "p90": round(sorted(samples)[min(len(samples) - 1, len(samples) * 9 // 10)], 1) if samples else None,
            "average": round(avg, 1) if avg is not None else None,
            "samples": len(samples),
        },
        "cpu_seconds": round(cpu, 3),
        "peak_rss_kib": peak_rss,
        "host_rx_bytes": rx,
        "last_progress_age_seconds": (round(wall - records[-1]["t"], 3)
                                      if records else None),
        "errors": errors[-8:],
    }
    if not records:
        result["classification"] = "no_measurement"
    elif result["final_downloaded_bytes"] == 0 and wall > 2:
        result["classification"] = "zero_throughput"
    elif wall - records[-1]["t"] > 5:
        result["classification"] = "stalled"
    elif ((result["throughput_bytes_per_sec"]["median"] or
           result["throughput_bytes_per_sec"]["average"] or 0) < 512 * 1024):
        result["classification"] = "slow"
    else:
        result["classification"] = "normal"
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", help="authorized/test media URL; omit for local control")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--seconds", type=int, default=20, help="local control duration")
    ap.add_argument("--height", type=int, default=720, help="local control height")
    ap.add_argument("--ytdlp", default=YTDLP)
    ap.add_argument("--format", help="yt-dlp format selector (e.g. 160)")
    ap.add_argument("--section", help='download section (e.g. "*0-20")')
    ap.add_argument("--app-profile", action="store_true",
                    help="use the app's EJS/POT/Deno/ffmpeg flags")
    ap.add_argument("--max-mib", type=int, default=64,
                    help="safety cap for the diagnostic download")
    ap.add_argument("--out", default=os.path.join(ROOT, "reports", "diagnose.json"))
    args = ap.parse_args()

    if not os.access(args.ytdlp, os.X_OK):
        print(f"SKIP: yt-dlp not executable: {args.ytdlp}", file=sys.stderr)
        return 77
    tmp = tempfile.mkdtemp(prefix="skdl-diagnose-")
    srv = None
    try:
        url = args.url
        if not url:
            url, srv = local_source(tmp, args.seconds, args.height)
            if not url:
                print("SKIP: need --url or ffmpeg for a local control", file=sys.stderr)
                return 77
        version = subprocess.run([args.ytdlp, "--version"], capture_output=True,
                                 text=True, timeout=20).stdout.strip()
        results = []
        for i in range(args.runs):
            work = os.path.join(tmp, f"run-{i}")
            print(f"run {i + 1}/{args.runs} ...", file=sys.stderr)
            results.append(run_once(args.ytdlp, url, work, args.timeout,
                                    args.format, args.app_profile, args.section,
                                    args.max_mib * 1024 * 1024))
        report = {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "yt_dlp_version": version,
            "source": sanitize_url(url),
            "command_flags": ["--ignore-config", "--no-warnings", "--no-playlist",
                              "--newline", "--progress-delta 1",
                              "--socket-timeout 15", "--retries 3",
                              "--app-profile" if args.app_profile else "--no-app-profile",
                              "--format " + (args.format or "default"),
                              "--max-mib " + str(args.max_mib)],
            "runs": results,
            "note": "Throughput is derived from yt-dlp byte deltas over wall "
                    "time. It distinguishes no measurement, zero throughput, "
                    "stall and slow; it does not attribute cause.",
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
