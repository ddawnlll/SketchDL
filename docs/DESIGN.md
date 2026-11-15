# SketchDL — Design ("Pencil on Paper")

A calm, crafted, non-kitschy tool: premium hand-drawn notebook +
editorial minimalism + subtle physical motion.

## Architecture

```
client
  |  HTTPS
  v
nginx  (TLS, request limits, SSE buffering off)
  |
  v
Axum router
  |-- auth guard + CSRF guard
  |-- SQLite (metadata)
  |-- static CSS + progress.js
  |-- SSE  /jobs/<id>/events  <---- EventBus (broadcast)
  |-- range file streaming
  `-- Tokio job task
        |-- yt-dlp inspect (run_capture, deadline)
        |-- yt-dlp download (process group, streamed lines)
        |-- progress parser + component aggregation
        |-- ffprobe verify
        `-- atomic publish -> data/complete/<id>.mp4
```

The server is one Rust process. A job is a Tokio task, not a separate
worker binary. `AppState` owns the SQLite connection (behind a mutex), a
broadcast event bus, a cancellation set, and a semaphore bounding
concurrent jobs. Completed files are streamed with `ReaderStream`; they
are never buffered in memory.

## Why raw HTML, not WASM

The UI is a form, a preview list, and a progress page. A WASM framework
would add a large binary, JS glue, and a second rendering pipeline before
first paint. Server-rendered HTML renders in ~2 ms, works with the
network cache disabled, and has no hydration step. The only client code
is `/assets/progress.js` (2.8 KB) on an active job page; it opens an
`EventSource`, updates a native `<progress>`, and removes the 3-second
meta-refresh fallback. No script means the fallback still works.

## Progress data flow

1. yt-dlp prints lines from `download:skdl-progress|done|total|estimate|
   speed|eta|format_id|vcodec|acodec`.
2. `ytdlp::parse_progress` strictly parses the numeric fields and the
   component identity. `ProgressTracker` keeps a high-water mark per
   format id, so a `video+audio` job does not go backwards when the
   second component starts.
3. Database writes are throttled to 500 ms. SSE publishes are throttled
   to 200 ms. A pause in progress does not stop the page from showing
   the last real value.
4. Terminal states publish one final event, then the stream closes and
   the page reloads to the READY/FAILED view.

## Tokens

| token | value | use |
|---|---|---|
| `--paper` | `#F6F5EF` | page canvas |
| `--ink` | `#252923` | text, strokes, borders |
| `--pencil` | `#D6D3C6` | shadows, rules |
| `--moss` | `#72865A` | progress, primary action |
| `--moss-dark` | `#4F5F3D` | primary hover, focus ring |
| `--terra` | `#B36F4D` | accent strokes |
| `--error` | `#9B3F31` | failures |

Type: system text stack for everything (legible at 200% zoom, no custom
font download). Body 17px/1.55, measure 34rem, mobile-first.

## Craft details

- Irregular hand-drawn borders: asymmetric radii
  (`14px 18px 14px 20px / 20px 14px 18px 14px`) shared by cards, buttons,
  and format strips, with a hard offset pencil shadow (no blur).
- Pencil strokes draw themselves with `stroke-dasharray` tracing
  (hero, checkmark). The pencil tip is a decorative CSS bob only.
- Buttons press with `translateY + scale`, shadow collapses.
- Progress is an inked paper track: `<progress>` filled with repeating
  moss hatches for known totals; indeterminate stages use a slow sliding
  hatch labeled "total size unknown" (never fake percentages). SSE
  updates the same element in place, so the bar moves without a reload.
- Page transitions via CSS cross-document view transitions, normal
  navigation fallback.
- `prefers-reduced-motion` collapses all animation; SVG strokes render
  complete (dashoffset 0).

## Accessibility

- Semantic HTML: labels, fieldsets for quality rows, `<progress>` with
  `aria-label`, state badges as text (not color alone).
- 48px minimum touch targets; visible 2.5px focus ring (moss).
- Contrast: ink on paper is 15.9:1; moss-dark links on paper 6.1:1;
  error 6.5:1. All pass WCAG AA.
- Every page works with JavaScript disabled; only live updates are
  enhanced by the one script.

## Pages

1. Login: padlock sketch, password field, limiter note.
2. Home: URL form + recent jobs.
3. Inspect: title, duration, quality radios with estimated sizes.
4. Job: stage label, bytes/speed/ETA from real server data, cancel.
   SSE live progress; 3-second meta-refresh fallback.
5. Ready: drawn checkmark, size/expiry, download link.
6. History: ruled list with state, cancel/retry/remove.
7. Errors: structured codes (`BOT_CHECK`, `FORMAT_UNAVAILABLE`, …) with
   safe explanations.

## Implementation notes

- **Progress template.** `--progress-template` takes
  `"<type>:<template>"`; the `<type>:` is consumed by yt-dlp's option
  parser and never printed. The literal marker therefore sits inside the
  template body (`download:skdl-progress|...`). The mock renders the
  template rather than hard-coding a line shape, so a mismatch fails the
  suite.
- **Process groups.** Each yt-dlp child calls `setsid()` before `exec`,
  so cancellation/timeout can kill the whole group (`kill(-pid,
  SIGKILL)`), including ffmpeg and Deno. `kill_on_drop` is a second line
  of defence.
- **Path resolution.** `--paths home:<absolute job dir>` makes yt-dlp's
  `after_move:filepath` absolute. The server only accepts a path inside
  that job dir ending in `.mp4`, then checks the file with ffprobe
  (MP4 container, H.264 video, AAC audio if present) before renaming it
  into `complete/`.
- **PO token.** Datacenter IPs get "Sign in to confirm you're not a bot"
  without a PO token. The bgutil WebPO provider is loaded as a plugin
  and passed two fixed `--extractor-args` flags:
  `youtubepot-bgutilscript:server_home=<--bgutil-home>` and
  `youtube:fetch_pot=always;player_client=mweb,tv,web_safari`. Two
  separate flags are required: semicolons inside one flag nest the later
  keys under the first extractor's group and silently disable
  `fetch_pot`.
- **SQLite.** One connection behind a mutex, `busy_timeout=5000`,
  `synchronous=FULL`, rollback journal. Every write is a short
  transaction; page reads are microseconds. Backups use `VACUUM INTO`.
- **Recovery.** On startup, active jobs have their old child process
  group killed, then are requeued up to 3 times. Conditional transitions
  prevent a late event from overwriting a terminal state.
