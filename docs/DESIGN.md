# SketchDL — Design ("Pencil on Paper")

A calm, crafted, non-kitschy tool: premium hand-drawn notebook + editorial
minimalism + subtle physical motion.

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
  hatch labeled "total size unknown" (never fake percentages).
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
- Everything works with JavaScript disabled (it is never present).

## Pages

1. Login: padlock sketch, password field, limiter note.
2. Home: URL form + recent jobs.
3. Inspect: title, duration, quality radios with estimated sizes.
4. Job: stage label, bytes/speed/ETA from real server data, refresh note,
   cancel. Meta-refresh (3 s) only while queued/processing.
5. Ready: drawn checkmark, size/expiry, download link.
6. History: ruled list with state, cancel/retry/remove.
7. Errors: structured codes (`BOT_CHECK`, `FORMAT_UNAVAILABLE`, …) with
   safe explanations.

## Implementation notes (linking and cleanup discipline)

- Per-call SQLite connections: every `db` function opens its own
  connection (per-thread state via `conn_depth`) and closes it before
  returning. `db.goose` deliberately does **not** use `defer` for
  cleanup: a Goose compiler inliner bug (reproduced with a minimal
  program; `-O0` correct, `-O1`/`-O2` wrong) emits deferred bodies on
  only one side of a return-value branch when a function is inlined
  and its result is consumed in a branch, leaking statements and
  connections. Until that is fixed in Goose, all exits in `db.goose`
  run `release`/`close_req` explicitly. Do not reintroduce `defer`.
- Spawned children close all inherited descriptors (`close_range`)
  before `exec`, and the listen socket is `FD_CLOEXEC`. Without this,
  setsid-detached workers keep the port bound after the server dies,
  so a restart fails with `EADDRINUSE`.
- yt-dlp size cap uses `--max-filesize` (the flag is named that in
  the vendored yt-dlp; there is no `--max-download-size`).
