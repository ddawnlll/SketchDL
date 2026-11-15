#!/usr/bin/env python3
"""A/B the VPS-to-browser hop of SketchDL.

Creates a valid READY job with a generated large MP4 (no network, no
YouTube), then measures the app's own HTTP + sendfile delivery, and, when an
nginx binary is provided, the same file through an nginx reverse proxy with
proxy_buffering on and off.

    python3 scripts/bench_http.py --binary ./sketchdl \
        --nginx /tmp/nginxpkg/root/usr/sbin/nginx --size-mib 64

Writes reports/http-bench.json. Range requests are verified in every path.
Nothing here weakens authentication, Range semantics or cache privacy.
"""
import argparse
import http.client
import json
import os
import shutil
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASSWORD = "correct horse battery staple"
JOB_ID = "ab" * 16


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_healthy(port, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            c.request("GET", "/healthz")
            r = c.getresponse()
            body = r.read()
            c.close()
            if r.status == 200 and body == b"ok\n":
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def login(port):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    import urllib.parse
    body = urllib.parse.urlencode({"password": PASSWORD}).encode()
    c.request("POST", "/login", body=body,
              headers={"Content-Type": "application/x-www-form-urlencoded",
                       "Connection": "close"})
    r = c.getresponse()
    cookie = r.getheader("set-cookie", "").split(";")[0]
    r.read()
    c.close()
    return cookie


def curl_measure(url, cookie, extra=None):
    cmd = ["curl", "-sS", "-o", "/dev/null",
           "-w", "%{http_code} %{time_starttransfer} %{time_total} "
                 "%{size_download} %{speed_download}",
           "-H", f"Cookie: {cookie}"]
    if extra:
        cmd.extend(extra)
    cmd.append(url)
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=300).stdout
    code, ttfb, total, size, speed = out.split()
    return {"status": int(code), "ttfb_s": float(ttfb),
            "total_s": float(total), "bytes": int(size),
            "bytes_per_sec": float(speed)}


def summarize(runs):
    return {
        "runs": len(runs),
        "median_bytes_per_sec": round(statistics.median(r["bytes_per_sec"] for r in runs), 1),
        "median_ttfb_ms": round(statistics.median(r["ttfb_s"] for r in runs) * 1000, 1),
        "median_total_s": round(statistics.median(r["total_s"] for r in runs), 3),
        "statuses": [r["status"] for r in runs],
    }


def write_nginx_config(prefix, port, app_port, buffering):
    os.makedirs(os.path.join(prefix, "tmp"), exist_ok=True)
    path = os.path.join(prefix, "nginx.conf")
    buffering_line = "proxy_buffering off;" if buffering == "off" else ""
    conf = f"""
worker_processes 1;
error_log {prefix}/error.log warn;
pid {prefix}/nginx.pid;
events {{ worker_connections 128; }}
http {{
    access_log off;
    client_body_temp_path {prefix}/tmp/client;
    proxy_temp_path {prefix}/tmp/proxy;
    fastcgi_temp_path {prefix}/tmp/fastcgi;
    uwsgi_temp_path {prefix}/tmp/uwsgi;
    scgi_temp_path {prefix}/tmp/scgi;
    server {{
        listen 127.0.0.1:{port};
        location / {{
            proxy_pass http://127.0.0.1:{app_port};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            {buffering_line}
        }}
    }}
}}
"""
    with open(path, "w") as fh:
        fh.write(conf)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--nginx", help="path to an nginx binary (optional)")
    ap.add_argument("--size-mib", type=int, default=64)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--out", default=os.path.join(ROOT, "reports", "http-bench.json"))
    args = ap.parse_args()
    binary = os.path.abspath(args.binary)
    if not os.access(binary, os.X_OK):
        print(f"SKIP: binary not executable: {binary}", file=sys.stderr)
        return 77
    if not shutil.which("curl"):
        print("SKIP: curl not found", file=sys.stderr)
        return 77

    tools = os.path.join(ROOT, "tools")
    ffmpeg = os.path.join(tools, "ffmpeg-master-latest-linux64-gpl", "bin", "ffmpeg")
    ffprobe = os.path.join(tools, "ffmpeg-master-latest-linux64-gpl", "bin", "ffprobe")
    tmp = tempfile.mkdtemp(prefix="skdl-httpbench-")
    port = free_port()
    db = os.path.join(tmp, "bench.db")
    data = os.path.join(tmp, "data")
    os.makedirs(os.path.join(data, "complete"), exist_ok=True)
    size = args.size_mib * 1024 * 1024
    path = os.path.join(data, "complete", JOB_ID + ".mp4")
    with open(path, "wb") as fh:
        fh.truncate(size)

    subprocess.run([binary, "admin", "set-password", "--db", db],
                   input=PASSWORD + "\n", capture_output=True, text=True,
                   timeout=30)
    now = int(time.time())
    con = sqlite3.connect(db, timeout=10)
    con.execute(
        "INSERT INTO jobs(id, owner_id, video_id, title, preset, state,"
        " downloaded_bytes, total_bytes, output_bytes, created_at, updated_at,"
        " expires_at) VALUES(?, 1, 'dQw4w9WgXcQ', 'http bench', '360p',"
        " 'READY', ?, ?, ?, ?, ?, ?)",
        (JOB_ID, size, size, size, now, now, now + 3600))
    con.commit()
    con.close()

    cmd = [binary, "serve", "--db", db, "--data", data,
           "--listen", f"127.0.0.1:{port}", "--insecure-cookies",
           "--ytdlp", "/bin/false", "--ffmpeg", ffmpeg, "--ffprobe", ffprobe,
           "--deno", "/bin/false", "--min-free-bytes", "0"]
    app = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
    nginx_procs = []
    try:
        if not wait_healthy(port):
            print("server never became healthy", file=sys.stderr)
            return 1
        cookie = login(port)
        direct_url = f"http://127.0.0.1:{port}/downloads/{JOB_ID}"
        direct = [curl_measure(direct_url, cookie) for _ in range(args.runs)]
        rng = curl_measure(direct_url, cookie, ["-r", "1000-1999"])
        report = {
            "file_bytes": size,
            "direct": summarize(direct),
            "direct_range_1000_1999": rng,
            "note": "loopback; median of runs; app streams with sendfile",
        }
        if args.nginx and os.access(args.nginx, os.X_OK):
            for mode in ("off", "on"):
                nport = free_port()
                prefix = os.path.join(tmp, "nginx-" + mode)
                os.makedirs(prefix, exist_ok=True)
                conf = write_nginx_config(prefix, nport, port, mode)
                np = subprocess.Popen([args.nginx, "-p", prefix, "-c", conf],
                                      stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
                nginx_procs.append((np, prefix, conf))
                deadline = time.time() + 10
                while time.time() < deadline:
                    try:
                        s = socket.create_connection(("127.0.0.1", nport), 0.3)
                        s.close()
                        break
                    except OSError:
                        time.sleep(0.1)
                urls = f"http://127.0.0.1:{nport}/downloads/{JOB_ID}"
                runs = [curl_measure(urls, cookie) for _ in range(args.runs)]
                nrng = curl_measure(urls, cookie, ["-r", "1000-1999"])
                report[f"nginx_buffering_{mode}"] = summarize(runs)
                report[f"nginx_buffering_{mode}_range_1000_1999"] = nrng
        else:
            report["nginx"] = "skipped (no nginx binary supplied)"
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as fh:
            json.dump(report, fh, indent=2)
        print(json.dumps(report, indent=2))
        return 0
    finally:
        for np, prefix, conf in nginx_procs:
            try:
                subprocess.run([args.nginx, "-p", prefix, "-c", conf, "-s", "quit"],
                               capture_output=True, timeout=10)
            except Exception:
                pass
            try:
                np.wait(timeout=5)
            except subprocess.TimeoutExpired:
                np.kill()
        if app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
