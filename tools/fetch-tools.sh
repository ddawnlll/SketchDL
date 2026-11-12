#!/bin/sh
# Fetch pinned SketchDL toolchain binaries into tools/ (development
# machines). Production installs to /usr/local/bin via docs/OPERATIONS.md.
set -eu
cd "$(dirname "$0")"
mkdir -p ejs

YTDLP_VERSION="${YTDLP_VERSION:-2026.10.26}"
EJS_VERSION="${EJS_VERSION:-0.8.0}"
EJS_WHEEL="yt_dlp_ejs-${EJS_VERSION}-py3-none-any.whl"

echo "yt-dlp ${YTDLP_VERSION} (official standalone)"
curl -fsSL -o yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp"
chmod +x yt-dlp

echo "yt-dlp-ejs ${EJS_VERSION} (challenge scripts, via PYTHONPATH)"
curl -fsSL -o "/tmp/${EJS_WHEEL}" "https://files.pythonhosted.org/packages/source/y/yt-dlp-ejs/${EJS_WHEEL}"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall('ejs')" "/tmp/${EJS_WHEEL}"
rm -f "/tmp/${EJS_WHEEL}"

echo "deno (latest 2.x stable)"
curl -fsSL -o deno.zip "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip"
python3 -c "import zipfile; zipfile.ZipFile('deno.zip').extractall('.')"
chmod +x deno
rm -f deno.zip

echo "ffmpeg/ffprobe (static GPL build)"
curl -fsSL -o ff.tar.xz "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"
tar -xf ff.tar.xz
rm -f ff.tar.xz

echo "installed:"
./yt-dlp --version
./deno --version | head -1
./ffmpeg-master-latest-linux64-gpl/bin/ffmpeg -version | head -1
