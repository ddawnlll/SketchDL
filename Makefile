# SketchDL build. Rust + Axum server, server-rendered HTML, tiny SSE script.
CARGO ?= cargo
BIN := sketchdl

.PHONY: all build check test run fmt clean tools

all: build

build:
	$(CARGO) build --release --manifest-path server/Cargo.toml
	cp server/target/release/sketchdl .$(BIN).new
	mv .$(BIN).new $(BIN)

check:
	$(CARGO) check --manifest-path server/Cargo.toml

test: build
	$(CARGO) test --manifest-path server/Cargo.toml
	python3 tests/integration.py --binary ./$(BIN)

run: build
	./$(BIN) serve --db data/sketchdl.db --data data --listen 127.0.0.1:8087 --insecure-cookies --ytdlp tools/yt-dlp --ffmpeg tools/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg --ffprobe tools/ffmpeg-master-latest-linux64-gpl/bin/ffprobe --deno tools/deno --ejs-parent tools/ejs --min-free-bytes 0

fmt:
	$(CARGO) fmt --manifest-path server/Cargo.toml

clean:
	$(CARGO) clean --manifest-path server/Cargo.toml
	rm -f $(BIN)

tools:
	bash tools/fetch-tools.sh
