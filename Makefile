# SketchDL (Goose) build. The Goose compiler is built from
# https://github.com/aardappel/goose (see README.md). Override GOOSE to
# point at a specific binary.
GOOSE ?= $(firstword $(wildcard /home/quant/src/goose/build/goose) $(shell command -v goose) ../goose/build/goose)
GOOSE_STDLIB ?= /home/quant/src/goose/stdlib
BIN := sketchdl

.PHONY: all build check test run fmt clean tools

all: build

build:
	GOOSE_STDLIB=$(GOOSE_STDLIB) $(GOOSE) build sketchdl.goose

check:
	GOOSE_STDLIB=$(GOOSE_STDLIB) $(GOOSE) check sketchdl.goose

test: build
	python3 tests/integration.py --binary ./$(BIN)

run: build
	./$(BIN) serve --db data/sketchdl.db --data data --listen 127.0.0.1:8087 --insecure-cookies --ytdlp tools/yt-dlp --ffmpeg tools/ffmpeg-master-latest-linux64-gpl/bin/ffmpeg --ffprobe tools/ffmpeg-master-latest-linux64-gpl/bin/ffprobe --deno tools/deno --ejs-parent tools/ejs --min-free-bytes 0

fmt:
	GOOSE_STDLIB=$(GOOSE_STDLIB) $(GOOSE) format *.goose

clean:
	rm -f $(BIN)

tools:
	bash tools/fetch-tools.sh
