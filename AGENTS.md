# Quickmaster — LiveView-Desktop-App

Audio mastering desktop app (Phoenix LiveView in a native window via
[elixir-desktop/desktop](https://github.com/elixir-desktop/desktop),
`Desktop.Window` + wxWebView). Drop an audio file, tweak the Dyson
compressor, listen to a preview, render a `_master` copy.

The product name, the OTP app (`:quickmaster`) and the module namespace
(`Quickmaster`) are all the same; the old `tischlampe` scaffold name is
gone.

## Development

    nix-shell            # elixir, erlang, wxGTK32, ffmpeg, mpv, ...
    run                  # mix run --no-halt; the wx window opens
    repl                 # iex -S mix
    test                 # mix test (skips audio tests if tools missing)
    make                 # rm result; nix-build (release derivation)
    form                 # nixpkgs-fmt; mix format

`ffmpeg`/`ffprobe` (decode/encode) and `mpv` (preview playback) come from
the shell. Without them the app still starts but shows a warning.

## Audio pipeline

Everything is mono per channel; the Dyson algorithm is a sample-by-sample
processor, so channels are independent.

- `lib/quickmaster/audio/dyson.ex` — pure-Elixir port of the SWH "Dyson
  compressor" (LADSPA id 1403), faithful to
  `ladspa/dyson_compress_1403.xml` including the `f_pow2` exponent
  approximation. Matches the native plugin within ~2e-4. Parameters match
  the LADSPA ports: `peak_limit` (dB, -30..0), `release_time` (s, 0..1),
  `cfrate` (0..1), `crate` (0..1). Defaults are 0.0, **0.25**, 0.5, 0.5 —
  the release-time default is raised above the plugin's nominal 0.0,
  because 0.0 makes the release filter extrapolate.
- `lib/quickmaster/audio/ffmpeg.ex` — probe/decode/encode via the ffmpeg
  executables. Decoding is raw f32le; encoding reuses the original
  container/codec and copies its metadata (`-map_metadata`).
- `lib/quickmaster/audio/waveform.ex` — peak envelopes with Nx.
- `lib/quickmaster/audio/master.ex` — streams a raw f32le file through one
  `Dyson` instance per channel, reporting progress per chunk; also writes
  the preview WAV slice.
- `lib/quickmaster/audio/player.ex` — preview playback through `mpv`
  (the webview cannot be trusted for audio output). `stop/1` kills mpv by
  OS pid; closing the port alone does not stop it.

## Workflow (Session)

`lib/quickmaster/session.ex` is a singleton GenServer and the only place
that owns state:

1. `load/2` copies the uploaded file, then decodes + computes the original
   waveform in a task.
2. Mastering runs automatically in a task and is recomputed (debounced,
   400 ms) whenever parameters change, so **preview and render read the
   cached mastered PCM** and stay cheap.
3. `preview/1` plays the 30 s window (30 % in) of `:original` or `:master`
   through `mpv`; `:original` does not wait for a fresh master.
4. `render/0` asks for a target path with the native save dialog and writes
   the original format/metadata there; `render_to/1` skips the dialog
   (tests). Progress is broadcast on the `"qm:session"` PubSub topic.

`Session.waveforms/0` returns both full waveforms and the preview-region
ones; the bottom bar shows the original and mastered preview region next to
each other, each with its own play button for A/B comparison.

## UI

- `lib/quickmaster_web/live/home_live.ex` — the effect panel is the start
  screen: rotary knobs with numeric inputs, original + mastered waveforms
  (inline SVG), preview and render buttons, progress bar. The window is
  sized 1180×840 so the whole panel fits without scrolling.
  Upload/decode progress is shown as a spinner left of `Open file…`.
  `Save` stays disabled until the background master is current.
- `lib/quickmaster/file_dialog.ex` — native `wxFileDialog` save dialog used
  by `Session.render/0` to pick the target path. wx APIs need
  `Desktop.Platform.Helpers.with_wx_env/1` in the calling process, otherwise
  they fail with `{:wx, :unknown_env}`.
- Files are opened with the `Open file…` button (`<input type=file>`), which
  uses the native GTK chooser under wxWebView.
- `priv/static/assets/js/phoenix.js` (Phoenix `Socket`) and `app.js`
  (LiveView client) are pristine copies from the deps; `LiveSocket`
  throws without the `Socket` class, so both are required.
- `priv/static/assets/js/quickmaster.js` boots LiveView with
  `window.Phoenix.Socket` and defines the `Knob` hook (pointer drag +
  arrow keys). Plain JS, no build step.
- `priv/static/assets/css/app.css` holds the outboard-compressor styling.

## Known limits

- The pure-Elixir DSP runs at roughly 100 k samples/s; a few minutes of
  stereo audio take on the order of a minute to master. It runs in the
  background with progress. Speeding this up would mean a NIF (the
  reference C is in `ladspa/`) or a rewrite in Nx.
- Membrane is intentionally not used: this is offline batch processing,
  so its streaming plugins would only add dependencies over plain file IO.
- `nix-build` produces `result/bin/quickmaster`; it is wrapped so
  `ffmpeg`, `mpv` and wxWidgets are on `PATH` at runtime.
- HTML5 drag and drop does not reach the page in wxWebView on Linux: the
  GTK widget is a drop destination and swallows the drag before WebKit
  delivers it. Erlang's wx bindings expose no drop target, so this cannot
  be fixed from Elixir. Use the `Open file…` button, which opens the native
  file chooser.
- Opening a file goes through a LiveView upload, so very large files are
  copied over the loopback websocket.