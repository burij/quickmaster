# Quickmaster — handoff notes

Desktop audio-mastering app: Phoenix LiveView rendered in a native window
by [elixir-desktop](https://github.com/elixir-desktop/desktop)
(`Desktop.Window` + wxWebView on Linux). Open an audio file, adjust the
Dyson compressor, A/B the 30 s preview, save a `_master` copy in the
original format and metadata.

Product name, OTP app (`:quickmaster`) and module namespace
(`Quickmaster`) are the same. The old `tischlampe` scaffold name is gone.

## Status

Feature-complete for the requested workflow:

- open a file (native GTK chooser via `<input type=file>`),
- four rotary knobs + numeric inputs, defaults `0.0 / 0.25 / 0.5 / 0.5`,
- original and mastered full waveforms (SVG),
- 30 s preview region (30 % in) for original **and** master, each with its
  own play button, A/B comparable,
- `Save` (native save dialog) writes the original container/codec and
  copies the metadata,
- background mastering with a progress bar; preview-first phase order.

Open work is in **Backlog** at the bottom. The only real weak spot is DSP
speed (see *Known limits*).

## Commands

```sh
nix-shell     # elixir, erlang, wxGTK32, ffmpeg, mpv
run           # mix run --no-halt — opens the wx window
repl          # iex -S mix
test          # mix test (audio tests are skipped when ffmpeg/mpv missing)
make          # rm result; nix-build  → result/bin/quickmaster
form          # nixpkgs-fmt lib.nix; mix format
```

`ffmpeg`/`ffprobe` (decode/encode) and `mpv` (preview) come from the shell
(`lib.nix`). Missing tools do not crash the app; the UI shows a warning.

## Repo conventions

- Work happens on branch `feat/quickmaster` (commits to `main` are blocked
  by a git guard).
- Commit style is enforced: **Conventional Commits, subject ≤ 72 chars**
  (e.g. `fix(preview): reliable stop, A/B auditioning, Save button`).
- `mix format --check-formatted` and `nixpkgs-fmt lib.nix` must pass.
- `git push`, `reset --hard`, `clean`, `branch -D` are blocked by the guard.
- `ladspa/` is the upstream SWH plugin source and the reference for the
  compressor. Never delete it; it was already lost once and restored with
  `git restore --source=HEAD --staged --worktree ladspa`.

## Architecture

### Audio (`lib/quickmaster/audio/`)

- `dyson.ex` — pure-Elixir port of the SWH "Dyson compressor" (LADSPA id
  1403), faithful to `ladspa/dyson_compress_1403.xml`, including the
  `f_pow2` exponent approximation (not real `exp`) and the fact that the
  plugin never sets `peaklimitdelay` (always 0). Verified against the
  compiled C plugin: max sample error < 5e-4. Parameters/ranges match the
  LADSPA ports; **release_time defaults to 0.25 s**, not the plugin's
  nominal 0.0 (0.0 makes the release filter extrapolate).
  - Per-sample state; one instance per channel; struct in, struct out.
  - `process_binary/2` is the hot path; `Master` uses `Dyson.step/2`.
- `ffmpeg.ex` — `probe/1`, `decode/3` (raw f32le, `-ss` **before** `-i` for
  fast seeking), `encode/5` (same container/codec + `-map_metadata`).
  `ffmpeg/0` and `ffprobe/0` fall back to `System.find_executable/1`.
- `master.ex` — `master_raw/6` streams an interleaved f32le file through one
  `Dyson` per channel, reporting `progress.(bytes_done, total)` per chunk;
  `slice_to_wav/6` writes the preview WAV.
- `waveform.ex` — `peaks/4` returns `[[{min,max}], ...]` per channel for the
  whole file or a `{from_frame, frames}` range. Direct binary scan; **do not
  replace with Nx** (see Known limits).
- `player.ex` — `mpv` playback. `stop/1` kills the process by `:os_pid`
  (closing the port is not enough).

### Session (`lib/quickmaster/session.ex`)

Singleton GenServer, the only owner of state, publishing on PubSub topic
`"qm:session"`. `advance/1` is the single decision step; one async task runs
at a time (`spawn_monitor`, results sent as `{:task_done|:task_error, …}`).

Phase order after a load (preview first so audio is available early):

1. `:decode_preview` — decode only the 30 s window (input seeking).
2. `:decode_full` — decode the whole file (full original waveform).
3. `:master_preview` — master the window ("Rendering preview").
4. `:master_full` — master the track; only then is `Save` enabled.

A parameter change stops a running master, then re-runs 3 + 4 (debounced
400 ms). State fields worth knowing:

| field | meaning |
| --- | --- |
| `input` | `%{path, name, size, origin: :upload | :native}` |
| `preview_src` | decoded 30 s window (original) |
| `raw` | full decoded original |
| `mastered_preview` / `preview_params` | mastered window + params used |
| `mastered` / `mastered_params` | full master + params used |
| `orig_waveform`, `master_waveform` | full peaks |
| `orig_preview`, `master_preview` | window peaks |
| `task` | `%{ref, pid, mon, kind}` or nil |
| `pending` | `nil | {:preview, :original | :master} | {:render, :ask | path}` |
| `player` | mpv port or nil |

API: `load/2` (uploads a temp file), `load_file/1` (native path, no copy),
`set_params/1`, `preview/1`, `stop_preview/0`, `render/0` (save dialog),
`render_to/1` (explicit path, used by tests), `snapshot/0`, `waveforms/0`,
`reset/0`. Broadcasts: `{:session, snapshot}`, `{:progress, phase, pct}`,
`{:waveforms, %{original, mastered, original_preview, mastered_preview}}`,
`{:playback, nil | :original | :master}`.

Playback never waits for a master: `preview(:original)` plays as soon as
`preview_src` exists (i.e. during `:decode_full`), `preview(:master)` only
needs phase 3.

### Web UI (`lib/quickmaster_web/`)

- `live/home_live.ex` — the effect panel **is** the start screen. Knob
  metadata lives in the `@params` module attribute and is exposed as
  `@param_defs` (module attributes are *not* accessible as `@params` inside
  `~H`; HEEx treats `@x` as an assign). Session broadcasts are handled in
  `handle_info/2`; progress updates are applied optimistically.
- `components/layouts/root.html.heex` — loads `phoenix.js`, `app.js`,
  `quickmaster.js` (all `defer`, in this order) and the favicon links.
- `components/layouts.ex` / `core_components.ex` / `controllers/*` are
  scaffold leftovers; `HomeLive` does not use `Layouts.app/1`.

### Static assets (`priv/static/`)

- `assets/js/phoenix.js` — pristine Phoenix `Socket` client
  (`deps/phoenix/priv/static/phoenix.js`).
- `assets/js/app.js` — pristine LiveView client
  (`deps/phoenix_live_view/priv/static/phoenix_live_view.js`).
- `assets/js/quickmaster.js` — boots LiveView and defines the `Knob` hook
  (pointer drag + arrow keys). No build step.
- `assets/css/app.css` — outboard-compressor styling.
- `images/logo.svg` — "QM" badge, used in the header and as SVG favicon;
  `images/icon.png` (256 px) is the window/taskbar icon (the `Desktop.Window`
  `icon:` path is relative to `priv/`, e.g. `"static/images/icon.png"`);
  `favicon.ico` is a 64 px PNG. Regenerate with
  `inkscape --export-type=png --export-filename=out.png -w 256 -h 256 priv/static/images/logo.svg`.

## Gotchas (each of these cost real debugging time)

1. `new LiveSocket("/live", Socket, opts)` — the **second argument must be a
   Socket class**. Passing an options object throws and the page silently
   stays non-interactive (no uploads, no knobs, no buttons). That is why
   `phoenix.js` exists and must load first.
2. wx calls need the wx env in the **calling** process:
   `Desktop.Platform.Helpers.with_wx_env(fn -> … end)`, otherwise
   `ErlangError {:wx, :unknown_env}` (hit when the Session opened the save
   dialog).
3. `Port.open({:spawn_executable, …})` does **not** search `PATH`; resolve
   with `System.find_executable/1` first.
4. HTML5 drag & drop never reaches the page in wxWebView on Linux: the GTK
   widget is a drop destination and swallows the drag. Erlang's wx bindings
   expose no drop target (`wxDropTarget` is unbound), so this is not fixable
   from Elixir without patching wx. Open files via the `Open file…` button.
5. `:array` as a ring buffer copies ~1000 words per sample; the Dyson delay
   line uses `:queue` instead. `min`/`max` BIFs are slower than inline `if`
   in the hot scan loops.
6. Nx's pure-Elixir `BinaryBackend` costs ~8 µs/element (~50× slower than a
   BEAM loop). Nx therefore has no place in this app and the dependency was
   removed.
7. LiveView 1.2: upload progress must be passed as
   `allow_upload(…, progress: &handle_progress/3)`; it is *not* a behaviour
   callback. Aggregate progress is on the entries
   (`entry.progress`), **not** on the `UploadConfig` (a `KeyError` there
   crashed the LiveView and made drops look broken).
8. `Session` is a singleton, so `Session`-touching tests are
   `async: false` and call `Session.reset()` in `setup`.
9. The preview starts with a fresh Dyson state at the window, so the
   mastered preview can differ slightly from the saved file at the same
   position. This is deliberate (speed over exactness).
10. `mount/3` must fetch `Session.waveforms/0` explicitly — waveforms are
    only *broadcast* when they change, so a LiveView that mounts later would
    otherwise render empty waveforms.

## Known limits / measured performance

Measured on this machine (load-dependent, treat as ballpark):

| work | time |
| --- | --- |
| Dyson, mono | ~180 k samples/s |
| 30 s stereo preview master | ~15 s |
| 4 min stereo full master | ~2 min |
| full waveform, 240 s stereo (900 buckets) | ~1.8 s |
| preview decode (30 s window) | ~0.2–2 s |

- The pure-Elixir DSP is the bottleneck. Real fixes: a NIF built from the C
  reference in `ladspa/` (~50× faster, needs `elixir_make` + nix build
  support) or per-channel parallelism (~2×).
- Opening a file went through a LiveView upload, so very large files are
  copied over the loopback websocket. `Session.load_file/1` already exists
  and is tested, so routing `Open file…` through a native wx open dialog
  (like `FileDialog.save/1`) would remove that copy.
- `nix-build` produces `result/bin/quickmaster`, wrapped so `ffmpeg`, `mpv`
  and wxWidgets are on `PATH`. `mixRelease` compiles the dependency tree
  from `deps/`, so `src = ./.` must keep `deps` (a source filter that
  excluded it broke the build).
- Membrane is intentionally not used: offline batch processing gains nothing
  from its streaming plugins over plain file IO.

## Tests

- `test/quickmaster/audio/dyson_test.exs` — compares the Elixir port against
  the compiled native plugin for two parameter sets.
- `test/quickmaster/audio/pipeline_test.exs` — ffmpeg decode/slice/encode,
  waveform, progress, mono.
- `test/quickmaster/session_test.exs` — load, phase order, render, preview
  peaks, missing file.
- `test/quickmaster_web/live/home_live_test.exs` — start screen, upload
  spinner, Save enabled/disabled, preview labels, progress labels.
- `test/test_helper.exs` excludes `:ffmpeg` / `:mpv` tagged tests when the
  tools are not on `PATH`; run inside `nix-shell` (or prepend the nix store
  bin dirs) to exercise them.

### Regenerating the DSP fixtures

`test/fixtures/dyson/{stress_in,stress_out,default_out}.f32` were produced
from the native plugin. To redo it:

```sh
mkdir -p /tmp/dysonref && cd ladspa
nix-shell -p perl perlPackages.ListMoreUtils perlPackages.XMLParser gcc --run \
  'perl ./makestub.pl dyson_compress_1403.xml > /tmp/dysonref/dyson_compress_1403.c'
cp ladspa.h ladspa-util.h /tmp/dysonref/ && : > /tmp/dysonref/config.h
# harness.c: `#include "dyson_compress_1403.c"`, connect the six LADSPA ports
# (0 peak_limit, 1 release_time, 2 cfrate, 3 crate, 4 in, 5 out) and run it
# file→file, args: sr peak_limit release_time cfrate crate in.f32 out.f32
gcc -O2 -o /tmp/dysonref/harness /tmp/dysonref/harness.c -lm -I/tmp/dysonref
```

Feed deterministic audio through it and store input and output next to each
other as raw f32le; `dyson_test.exs` compares the Elixir port against them.

## Backlog

1. **DSP speed** (biggest win): NIF from `ladspa/` or per-channel `Task`s.
2. Native **open** dialog to avoid the websocket copy for huge files
   (`FileDialog.open/0` was removed again; re-add it like `save/1`, then call
   `Session.load_file/1`).
3. Preview-window length is a hard-coded 30 s / 30 % (`@preview_seconds`,
   `@preview_ratio` in `Session`); expose it if users ask.
4. `render/0` currently suggests the path next to the opened file (or
   `~/Music` for uploads); a remembered last-used directory would be nicer.
5. Real drag & drop would need a wxWidgets patch (`gtk_drag_dest_unset`) —
   out of scope so far.
