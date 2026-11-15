#!/usr/bin/env python3
"""Mock yt-dlp for SketchDL integration tests (stdlib only, no network).

Acts like the real yt-dlp for the exact argv shapes SketchDL uses:

  inspect:  --skip-download --dump-single-json <url>   -> canned JSON
  download: --progress-template ... --print after_move:filepath
            --paths home:<dir> --paths temp:<dir> -o %(id)s.%(ext)s
            -> emits progress lines, copies a REAL h264/aac MP4 template
               into the job dir, prints the after_move path, exits 0.

Progress lines are rendered from the --progress-template argv value the
same way yt-dlp renders it: the leading "<type>:" is the template's
dictionary key and is NOT printed; the remainder is expanded field by
field, with missing values as "NA". Rendering for real (instead of
hard-coding a line shape) is what makes a template/parser mismatch fail
the suite instead of passing silently.

Failure knobs via MOCK_YTDLP:
  ok (default), bot, private, empty, slow (40s, for cancel/kill tests),
  crash (prints partial, exits 1), no_output (exit 0, no file).

Every invocation appends its argv (NUL separated, one line) to MOCK_CAPTURE.
"""
import json
import os
import re
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


def progress_values(downloaded, total, speed, eta, format_id="18",
                    vcodec="avc1.42001E", acodec="mp4a.40.2"):
    return {
        "downloaded_bytes": downloaded,
        "total_bytes": total,
        "total_bytes_estimate": total,
        "speed": speed,
        "eta": eta,
        "info": {
            "format_id": format_id,
            "vcodec": vcodec,
            "acodec": acodec,
        },
    }


FIELD_RE = re.compile(r"%\((?P<keys>[^)]+)\)(?P<fmt>s|d)")


def render_template(template, progress):
    """Expand a yt-dlp progress template against one progress dict.

    Supports %(progress.KEY)s and yt-dlp's alternate form
    %(progress.A,progress.B)s (first key that has a value wins).
    Anything without a value renders as NA.
    """

    def sub(match):
        for key in match.group("keys").split(","):
            key = key.strip()
            if key.startswith("progress."):
                value = progress.get(key[len("progress."):])
                if value is not None:
                    return str(value)
            elif key.startswith("info."):
                value = progress.get("info", {}).get(key[len("info."):])
                if value is not None:
                    return str(value)
        return "NA"

    return FIELD_RE.sub(sub, template)


def render_progress_line(argv, progress):
    """The line yt-dlp would print for this template, or None if absent."""
    template = get_flag(argv, "--progress-template")
    if template is None:
        return None
    # "<type>:<template>": the type key is consumed by the option parser.
    if ":" in template:
        kind, template = template.split(":", 1)
        if kind not in ("download", "download-title", "postprocess", "postprocess-title"):
            template = kind + ":" + template
    return render_template(template, progress)


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
            line = render_progress_line(
                argv, progress_values(done, total, 300000, 40 - step))
            if line:
                print(line, flush=True)
            time.sleep(1)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "no_output":
        line = render_progress_line(argv, progress_values(100, 100, 10000, 0))
        if line:
            print(line, flush=True)
        sys.exit(0)

    if mode == "va":
        # Two components, like yt-dlp's video+audio format spec: video
        # finishes, then audio starts. A single-component parser would reset
        # the whole job to 0 B at the audio stage.
        vtotal = os.path.getsize(TEMPLATE)
        atotal = 3449447
        for step in range(0, 5):
            done = vtotal * step // 4
            line = render_progress_line(
                argv, progress_values(done, vtotal, 400000, 4 - step,
                                      "137", "avc1.640028", "none"))
            if line:
                print(line, flush=True)
            time.sleep(0.5)
        for step in range(0, 5):
            done = atotal * step // 4
            line = render_progress_line(
                argv, progress_values(done, atotal, 120000, 4 - step,
                                      "140", "none", "mp4a.40.2"))
            if line:
                print(line, flush=True)
            time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "chatty":
        # >3 MiB on stderr interleaved with progress. Before the parent
        # polled both pipes, the child blocked on a full stderr pipe and the
        # job looked like a stalled download.
        total = os.path.getsize(TEMPLATE)
        filler = "warning: " + ("x" * 900) + "\n"
        for i in range(3500):
            sys.stderr.write(filler)
            if i % 250 == 0:
                line = render_progress_line(
                    argv, progress_values(total * i // 3500, total, 800000, 1))
                if line:
                    print(line, flush=True)
        line = render_progress_line(
            argv, progress_values(total, total, 800000, 0))
        if line:
            print(line, flush=True)
        time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "bigstdout":
        # >64 KiB of non-progress stdout, then the only progress record and
        # the after_move path. A tail that trims the wrong end loses both.
        for i in range(1400):
            print("unrelated extractor chatter line " + ("y" * 50))
        total = os.path.getsize(TEMPLATE)
        line = render_progress_line(
            argv, progress_values(total, total, 600000, 0))
        if line:
            print(line, flush=True)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "splitline":
        # One record split across writes with a delay: the parser must keep
        # the partial line until the newline arrives.
        total = os.path.getsize(TEMPLATE)
        line = render_progress_line(
            argv, progress_values(total // 2, total, 12345.67, 2))
        if line:
            cut = len(line) // 2
            sys.stdout.write(line[:cut])
            sys.stdout.flush()
            time.sleep(0.4)
            sys.stdout.write(line[cut:] + "\n")
            sys.stdout.flush()
        time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "crlf":
        total = os.path.getsize(TEMPLATE)
        line = render_progress_line(
            argv, progress_values(total, total, 700000, 0))
        if line:
            sys.stdout.write(line + "\r\n")
            sys.stdout.flush()
        time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "unknown":
        line = render_progress_line(
            argv, progress_values(1234, None, None, None))
        if line:
            print(line, flush=True)
        time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "stalled":
        total = os.path.getsize(TEMPLATE)
        line = render_progress_line(
            argv, progress_values(total // 2, total, 0, None))
        if line:
            print(line, flush=True)
        time.sleep(0.5)
        shutil.copyfile(TEMPLATE, out)
        print(out)
        sys.exit(0)

    if mode == "chatterror":
        # Oldest stderr is noise, newest is the real reason. pop_n trimming
        # kept the noise and lost this line.
        for i in range(20):
            sys.stderr.write("old warning line %d %s\n" % (i, "z" * 900))
        sys.stderr.write(
            "ERROR: [youtube] dQw4w9WgXcQ: HTTP Error 429: Too Many Requests\n")
        sys.stderr.flush()
        sys.exit(1)

    if mode == "silent":
        # No output, no file: exercises the real deadline.
        time.sleep(10)
        sys.exit(0)

    if mode == "crash":
        line = render_progress_line(argv, progress_values(1024, None, 50000, None))
        if line:
            print(line, flush=True)
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
        eta = 6 - step if step < 6 else None
        line = render_progress_line(argv, progress_values(done, total, 500000, eta))
        if line:
            print(line, flush=True)
        time.sleep(0.4 if mode == "ok" else 0)
    shutil.copyfile(TEMPLATE, out)
    print(out)
    sys.exit(0)


if __name__ == "__main__":
    main()
