#!/usr/bin/env python3
"""SketchDL benchmark: real measurements, no fabrication.

Measures against a running server with the mock yt-dlp:
  - idle RSS/PSS of the server process (+ worker tree while downloading)
  - p50/p95 latency of GET / (loopback)
  - cold start time
  - CSS/page weight (compressed + uncompressed)

Usage: python3 scripts/bench.py [--binary ./sketchdl] [--requests 200]
Writes reports/bench-raw.json next to the script.
"""
import argparse
import gzip
import http.client
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def smaps_pss(pid):
    try:
        with open(f"/proc/{pid}/smaps_rollup") as fh:
            for line in fh:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return -1


def rss(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return -1


def children(pid):
    kids = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as fh:
                parts = fh.read().rsplit(")", 1)[1].split()
                ppid = int(parts[1])
            if ppid == pid:
                kids.append(int(name))
        except (OSError, IndexError, ValueError):
            pass
    return kids


def tree_pss(pid):
    total = smaps_pss(pid)
    if total < 0:
        return -1
    for k in children(pid):
        p = smaps_pss(k)
        if p >= 0:
            total += p
    return total


def wait_healthy(port, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/healthz")
            r = c.getresponse()
            r.read()
            c.close()
            if r.status == 200:
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--requests", type=int, default=200)
    args = ap.parse_args()
    binary = os.path.abspath(args.binary)

    tools = os.path.join(ROOT, "tools")
    ffmpeg = os.path.join(tools, "ffmpeg-master-latest-linux64-gpl", "bin", "ffmpeg")
    ffprobe = os.path.join(tools, "ffmpeg-master-latest-linux64-gpl", "bin", "ffprobe")
    mock = os.path.join(ROOT, "tests", "mock-yt-dlp.py")
    template = os.path.join(ROOT, "tests", "test-template.mp4")

    tmp = tempfile.mkdtemp(prefix="sketchdl-bench-")
    port = free_port()
    db = os.path.join(tmp, "bench.db")
    data = os.path.join(tmp, "data")

    subprocess.run([ffmpeg, "-y", "-f", "lavfi", "-i", "color=c=black:s=320x240:d=3",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", template],
                   check=True, capture_output=True, timeout=60)

    env = dict(os.environ)
    env["MOCK_YTDLP"] = "ok"
    subprocess.run([binary, "admin", "set-password", "--db", db],
                   input="correct horse battery staple\n", capture_output=True, text=True, timeout=30)

    cmd = [binary, "serve", "--db", db, "--data", data,
           "--listen", f"127.0.0.1:{port}", "--insecure-cookies",
           "--ytdlp", mock, "--ffmpeg", ffmpeg, "--ffprobe", ffprobe,
           "--deno", "/nonexistent/deno", "--min-free-bytes", "0",
           "--download-timeout", "30"]
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    cold_start_ms = None
    try:
        if not wait_healthy(port, timeout=60):
            print("server never became healthy", file=sys.stderr)
            return 1
        cold_start_ms = (time.time() - t0) * 1000

        # log in
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        body = urllib.parse.urlencode({"password": "correct horse battery staple"}).encode()
        c.request("POST", "/login", body=body, headers={"Content-Type": "application/x-www-form-urlencoded", "Connection": "close"})
        r = c.getresponse()
        cookie = r.getheader("set-cookie", "")
        r.read()
        c.close()
        assert r.status == 303, r.status
        cookie = cookie.split(";")[0]

        def get(path):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            c.request("GET", path, headers={"Cookie": cookie, "Connection": "close"})
            r = c.getresponse()
            data = r.read()
            st = r.status
            c.close()
            return st, data

        idle_rss = rss(proc.pid)
        idle_pss = smaps_pss(proc.pid)
        time.sleep(1)
        idle_rss = rss(proc.pid)
        idle_pss = smaps_pss(proc.pid)

        # latency of GET /
        lat = []
        for _ in range(args.requests):
            s = time.time()
            st, data = get("/")
            lat.append((time.time() - s) * 1000)
        lat.sort()
        p50 = lat[len(lat) // 2]
        p95 = lat[int(len(lat) * 0.95)]

        # page weight
        st, home = get("/")
        st, css = get("/assets/style.css")
        st, js = get("/assets/progress.js")
        js_bytes = len(js) if st == 200 else 0

        # peak tree memory during a download
        st, _ = get("/")
        # enqueue a job via the UI flow
        s = time.time()
        c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
        home_text = home.decode(errors="replace")
        import re
        csrfm = re.search(r'name="csrf" value="([^"]+)"', home_text)
        csrf = csrfm.group(1) if csrfm else ""
        c.close()
        def form(path, fields):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
            c.request("POST", path, body=urllib.parse.urlencode(fields).encode(),
                      headers={"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded", "Connection": "close"})
            r = c.getresponse()
            data = r.read()
            st = r.status
            loc = r.getheader("location", "")
            c.close()
            return st, loc, data
        st, loc, _ = form("/inspect", {"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "csrf": csrf})
        token = loc.rsplit("/", 1)[-1]
        st, loc, _ = form("/jobs", {"inspect": token, "preset": "360p", "csrf": csrf})
        job_id = loc.rsplit("/", 1)[-1]
        peak_tree_pss = 0
        deadline = time.time() + 90
        while time.time() < deadline:
            tree = tree_pss(proc.pid)
            if tree > peak_tree_pss:
                peak_tree_pss = tree
            st, body = get(f"/jobs/{job_id}")
            if b"Download MP4" in body:
                break
            time.sleep(0.2)
        final_tree_pss = tree_pss(proc.pid)

        out = {
            "binary": binary,
            "cold_start_ms": cold_start_ms,
            "idle_rss_kib": idle_rss,
            "idle_pss_kib": idle_pss,
            "get_root_p50_ms": p50,
            "get_root_p95_ms": p95,
            "home_bytes": len(home),
            "css_bytes": len(css),
            "css_gzip_bytes": len(gzip.compress(css)),
            "js_bytes": js_bytes,
            "peak_tree_pss_kib_during_download": peak_tree_pss,
            "final_tree_pss_kib": final_tree_pss,
            "requests": args.requests,
            "note": "mock yt-dlp emits a real 3s h264/aac file; PSS via /proc/*/smaps_rollup",
        }
        print(json.dumps(out, indent=2))
        os.makedirs(os.path.join(ROOT, "reports"), exist_ok=True)
        with open(os.path.join(ROOT, "reports", "bench-raw.json"), "w") as fh:
            json.dump(out, fh, indent=2)
        return 0
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


if __name__ == "__main__":
    sys.exit(main())
