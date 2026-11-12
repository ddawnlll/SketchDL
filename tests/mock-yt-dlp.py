#!/usr/bin/env python3
"""Mock yt-dlp for SketchDL integration tests (stdlib only, no network).

Acts like the real yt-dlp for the exact argv shapes SketchDL uses:

  inspect:  --skip-download --dump-single-json <url>   -> canned JSON
  download: --progress-template ... --print after_move:filepath
            --paths home:<dir> --paths temp:<dir> -o %(id)s.%(ext)s
            -> emits progress lines, copies a REAL h264/aac MP4 template
               into the job dir, prints the after_move path, exits 0.

Failure knobs via MOCK_YTDLP:
  ok (default), bot, private, empty, slow (40s, for cancel/kill tests),
  crash (prints partial, exits 1), no_output (exit 0, no file).

Every invocation appends its argv (NUL separated, one line) to MOCK_CAPTURE.
"""
import json
import os
import shutil
import sys
import time

VIDEO_ID = "dQw4w9WgXcQ"
TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-template.mp4")

FORMATS = [
    {"format_id": "233", "ext": "mp4", "vcodec": None, "acodec": None,
     "height": None, "format_note": "Default, low"},
    {"format_id": "139", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.5",
     "filesize": 1300631, "format_note": "low"},
    {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2",
     "filesize": 3449447},
    {"format_id": "269", "ext": "mp4", "vcodec": "avc1.4D400C", "acodec": "none",
     "height": 144, "filesize": 2058142},
    {"format_id": "394", "ext": "mp4", "vcodec": "av01.0.00M.08", "acodec": "none",
     "height": 144, "filesize": 1505504},
    {"format_id": "134", "ext": "mp4", "vcodec": "avc1.4D401E", "acodec": "none",
     "height": 360, "filesize": 8390921},
    {"format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2",
     "height": 360, "filesize": 11832459},
    {"format_id": "136", "ext": "mp4", "vcodec": "avc1.4D401F", "acodec": "none",
     "height": 720, "filesize": 26455880},
    {"format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none",
     "height": 1080, "filesize": 80911999},
    {"format_id": "399", "ext": "mp4", "vcodec": "av01.0.08M.08", "acodec": "none",
     "height": 1080, "filesize": 30415996},
]

METADATA = {
    "id": VIDEO_ID,
    "title": "Rick Astley - Never Gonna Give You Up (Official Video)",
    "duration": 213,
    "formats": FORMATS,
}


def log_argv(argv):
    cap = os.environ.get("MOCK_CAPTURE")
    if not cap:
        return
    with open(cap, "a", encoding="utf-8") as fh:
        fh.write("\x00".join(argv) + "\n")


def get_flag(argv, name):
    for i, a in enumerate(argv):
        if a == name and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith(name + "="):
            return a[len(name) + 1:]
    return None


def paths_of(argv):
    home = None
    temp = None
    for i, a in enumerate(argv):
        v = None
        if a == "--paths" and i + 1 < len(argv):
            v = argv[i + 1]
        elif a.startswith("--paths="):
            v = a[len("--paths="):]
        if v is not None:
            if v.startswith("home:"):
                home = v[len("home:"):]
            elif v.startswith("temp:"):
                temp = v[len("temp:"):]
    return home, temp


def main():
    argv = sys.argv[1:]
    log_argv(argv)
    mode = os.environ.get("MOCK_YTDLP", "ok")

    # inspect mode
    if "--dump-single-json" in argv:
        if mode == "bot":
            print("[youtube] Sign in to confirm you're not a bot.", file=sys.stderr)
            sys.exit(1)
        if mode == "private":
            print("ERROR: [youtube] dQw4w9WgXcQ: Private video. Sign in if you've been granted access",
                  file=sys.stderr)
            sys.exit(1)
        if mode == "empty":
            print("{}")
            sys.exit(0)
        if mode == "crash":
            print("unexpected json: {broken", file=sys.stdout)
            sys.exit(1)
        print(json.dumps(METADATA))
        sys.exit(0)

    # download mode (anything with --progress-template)
    if "--progress-template" not in argv:
        print("mock-yt-dlp: unexpected argv: " + " ".join(argv), file=sys.stderr)
        sys.exit(2)

    home, temp = paths_of(argv)
    if not home:
        print("mock-yt-dlp: missing --paths home:", file=sys.stderr)
        sys.exit(2)
    os.makedirs(home, exist_ok=True)
    if temp:
        os.makedirs(temp, exist_ok=True)
    out = os.path.join(home, VIDEO_ID + ".mp4")

    if mode == "slow":
        total = 700000
        # 40 progress lines with delays -> exercises progress persistence,
        # cancellation, timeout, and SIGKILL-mid-download recovery.
        for step in range(0, 41):
            done = total * step // 40
            print(f"download:{done}|{total}|300000|{40 - step}", flush=True)
            time.sleep(1)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "no_output":
        print("download:100|100|10000|0")
        sys.exit(0)

    if mode == "crash":
        print("download:1024|NA|50000|NA")
        print("ERROR: [youtube] dQw4w9WgXcQ: HTTP Error 429: Too Many Requests",
              file=sys.stderr)
        sys.exit(1)

    if mode == "bot":
        print("ERROR: [youtube] dQw4w9WgXcQ: Sign in to confirm you're not a bot.",
              file=sys.stderr)
        sys.exit(1)

    # ok: stepped progress, real file copy, after_move line.
    total = os.path.getsize(TEMPLATE)
    for step in range(0, 9):
        done = total * step // 8
        print(f"download:{done}|{total}|500000|{6 - step if step < 6 else 'NA'}", flush=True)
        time.sleep(0.4 if mode == "ok" else 0)
    shutil.copyfile(TEMPLATE, out)
    print(out)
    sys.exit(0)


if __name__ == "__main__":
    main()
