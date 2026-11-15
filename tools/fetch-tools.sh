#!/bin/sh
# Fetch pinned SketchDL toolchain binaries into tools/ (development
# machines). Production installs to /usr/local/bin via docs/OPERATIONS.md.
#
# The script is cwd-independent: every path is resolved from its own
# location, and every downloaded executable is checked before use. A broken
# optional component (Deno / the WebPO provider) fails here with an
# actionable message instead of silently degrading downloads later.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

YTDLP_VERSION="${YTDLP_VERSION:-2026.10.26}"
EJS_VERSION="${EJS_VERSION:-0.8.0}"
EJS_WHEEL="yt_dlp_ejs-${EJS_VERSION}-py3-none-any.whl"
BGUTIL_VERSION="${BGUTIL_VERSION:-2.0.2}"
BGUTIL_WHEEL="bgutil_ytdlp_pot_provider-${BGUTIL_VERSION}-py3-none-any.whl"
DENO_BIN="$SCRIPT_DIR/deno"

TMP_DIR="$SCRIPT_DIR/.fetch-tmp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" ejs
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "fetch-tools: required command '$1' not found" >&2
        exit 1
    }
}
need curl
need python3
need git

download() {
    # download URL DEST (atomic move into place on success)
    dest="$2"
    tmp="$TMP_DIR/$(basename "$dest").part"
    echo "  -> $dest"
    curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$1"
    mv -f "$tmp" "$dest"
}

echo "yt-dlp ${YTDLP_VERSION} (official standalone)"
download "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp" \
    "$SCRIPT_DIR/yt-dlp"
chmod +x "$SCRIPT_DIR/yt-dlp"
"$SCRIPT_DIR/yt-dlp" --version >/dev/null || {
    echo "fetch-tools: downloaded yt-dlp does not run" >&2
    exit 1
}
got=$("$SCRIPT_DIR/yt-dlp" --version)
[ "$got" = "$YTDLP_VERSION" ] || {
    echo "fetch-tools: yt-dlp version mismatch: wanted $YTDLP_VERSION, got $got" >&2
    exit 1
}

echo "yt-dlp-ejs ${EJS_VERSION} (challenge scripts)"
download "https://files.pythonhosted.org/packages/source/y/yt-dlp-ejs/${EJS_WHEEL}" \
    "$TMP_DIR/${EJS_WHEEL}"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$TMP_DIR/${EJS_WHEEL}" ejs
[ -d "$SCRIPT_DIR/ejs/yt_dlp_ejs" ] || {
    echo "fetch-tools: EJS wheel did not unpack into ejs/yt_dlp_ejs" >&2
    exit 1
}

echo "bgutil WebPO POT provider ${BGUTIL_VERSION} (plugin into ejs/, server via Deno)"
curl -fsSL --retry 3 --connect-timeout 15 \
    -o "$TMP_DIR/bgutil-meta.json" \
    "https://pypi.org/pypi/bgutil-ytdlp-pot-provider/${BGUTIL_VERSION}/json"
BGUTIL_URL=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['urls'][0]['url'])" \
    "$TMP_DIR/bgutil-meta.json")
download "$BGUTIL_URL" "$TMP_DIR/${BGUTIL_WHEEL}"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$TMP_DIR/${BGUTIL_WHEEL}" ejs
[ -d "$SCRIPT_DIR/ejs/yt_dlp_plugins/extractor" ] || {
    echo "fetch-tools: bgutil plugin did not unpack into ejs/yt_dlp_plugins" >&2
    exit 1
}

echo "Deno (latest 2.x stable)"
case "$(uname -m)" in
    x86_64|amd64) DENO_ARCH=x86_64-unknown-linux-gnu ;;
    aarch64|arm64) DENO_ARCH=aarch64-unknown-linux-gnu ;;
    *) echo "fetch-tools: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
download "https://github.com/denoland/deno/releases/latest/download/deno-${DENO_ARCH}.zip" \
    "$TMP_DIR/deno.zip"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$TMP_DIR/deno.zip" "$TMP_DIR"
mv -f "$TMP_DIR/deno" "$DENO_BIN"
chmod +x "$DENO_BIN"
"$DENO_BIN" --version >/dev/null || {
    echo "fetch-tools: downloaded Deno does not run at $DENO_BIN" >&2
    exit 1
}

echo "bgutil server ${BGUTIL_VERSION} (generation script sources + npm deps)"
rm -rf "$SCRIPT_DIR/bgutil-ytdlp-pot-provider"
git clone --quiet --single-branch --branch "$BGUTIL_VERSION" \
    https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git \
    "$SCRIPT_DIR/bgutil-ytdlp-pot-provider"
# Absolute Deno path: a relative ../deno resolves inside the cloned repo,
# not this tools directory, and made a clean `make tools` fail.
(cd "$SCRIPT_DIR/bgutil-ytdlp-pot-provider/server" && \
    "$DENO_BIN" install --allow-scripts=npm:canvas --frozen) || {
    echo "fetch-tools: Deno dependency install failed in bgutil server" >&2
    exit 1
}
[ -f "$SCRIPT_DIR/bgutil-ytdlp-pot-provider/server/src/generate_once.ts" ] || {
    echo "fetch-tools: bgutil server sources are missing" >&2
    exit 1
}

echo "ffmpeg/ffprobe (static GPL build)"
download "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz" \
    "$TMP_DIR/ff.tar.xz"
tar -xJf "$TMP_DIR/ff.tar.xz" -C "$SCRIPT_DIR"
[ -x "$SCRIPT_DIR/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg" ] || {
    echo "fetch-tools: ffmpeg archive did not produce the expected tree" >&2
    exit 1
}

echo "installed:"
"$SCRIPT_DIR/yt-dlp" --version
"$DENO_BIN" --version | head -1
"$SCRIPT_DIR/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg" -version | head -1
