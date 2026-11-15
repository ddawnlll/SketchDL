# Benchmark and diagnostic reports

All files here were produced on the same development host (6 visible
vCPUs, Linux, Goose `-O2`, vendored yt-dlp 2026.10.26, ffmpeg static GPL)
on 2026-11-15. They are raw measurement output, not marketing claims.

| file | what it measures | conditions |
|---|---|---|
| `bench-raw.json` | idle/peak RSS/PSS, page latency, page weight | mock yt-dlp, loopback |
| `http-bench.json` | app sendfile vs nginx proxy, 128 MiB file, Range | loopback, 5 runs, extracted nginx 1.26.3 |
| `quota-bench.json` | `systemd-run --user --scope CPUQuota=50%/100%/none` | generated 20 s 720p, download + remux, 2 runs |
| `fragments-bench.json` | yt-dlp `-N 1/2/4/8` on HLS with 100 ms/request latency | generated 30 s HLS, 3 runs |
| `diagnose-control.json` | diagnostic path correctness | generated 10 s 720p, loopback, 3 runs |
| `diagnose-live-bbb.json` | real YouTube extraction + transfer | Big Buck Bunny (Blender Foundation, CC-BY), format 160, app's EJS/POT flags |

## Findings

- **0 B UI**: fixed by the sentinel-inside-template parse, incremental
  record parsing, exact/estimate totals, and per-component aggregation.
  The real yt-dlp contract test in `tests/integration.py` asserts the
  wire shape, not a hand-written mock line.
- **Live transfer**: the CC-BY probe reached the first progress record
  after 23.5 s (CPU-heavy EJS/PO-token extraction), then moved 4.32 MB
  in the 0.047 s between the last two progress records (~91 MB/s
  implied; progress-delta 1 only exposes a first/last sample for such a
  fast transfer). Peak process-tree RSS was 409 MiB. The reported
  ~200 KB/s was **not reproduced** from this host; it cannot be
  attributed to SketchDL's argv, which has no rate cap.
- **End-to-end app probe**: a live 144p job reached READY; downloaded
  bytes were monotonic, the job page served the MP4, and a Range request
  returned 206/100 bytes. Extraction/PO-token startup (~23 s) dominated
  this short job; the transfer itself did not. Before the audio-selection
  fix this 144p job pulled 35.1 MB (the 388k m4a track plus 4 MB of
  video); after it pulled 6.77 MB, a 5.2x reduction for the same preset.
  Stage labels observed: `starting`, `merging`, `verifying`.
- **CPU quota**: on this host yt-dlp was CPU-bound on the local control
  (19.9 MB in 6.9 s at 100% versus 13.6 s at 50%). The unit now uses
  `CPUQuota=100%` (one bounded core) instead of half a core.
- **Fragment concurrency**: with a 100 ms/request HLS delay, medians
  were 8.06 s (-N 1), 8.04 s (-N 2), 8.68 s (-N 4), 7.90 s (-N 8), all
  zero-failure. No meaningful gain was measured, so the default stays
  `--concurrent-fragments 1` (bounded 1..16 for operators).
- **VPS→browser**: direct app delivery of a 128 MiB file measured
  ~1.28 GB/s and ~2.6 ms TTFB after removing the accept-loop sleep
  (previously ~104 ms TTFB). Through nginx: buffering on ~285 MB/s /
  5.1 ms TTFB; buffering off ~120 MB/s / 20.6 ms. Buffering stays on,
  with a 64 MiB per-request temp cap.
- **Unresolved**: a live YouTube transfer at ~200 KB/s was not
  reproduced. Candidate causes that would need the production host's
  measurements are source-side throttling for a specific video/client,
  VPS routing, and CPU starvation during extraction. `scripts/diagnose.py`
  is the reproducible way to capture that evidence.
