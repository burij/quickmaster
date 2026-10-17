# Quickmaster — LiveView-Desktop-App

Audio mastering desktop app (Phoenix LiveView in a native window via
[elixir-desktop/desktop](https://github.com/elixir-desktop/desktop),
`Desktop.Window` + wxWebView). Drop an audio file, tweak the Dyson
compressor, listen to a preview, render a `_master` copy.

The Elixir module namespace is still `Tischlampe` (the scaffold name);
the product name is **Quickmaster**.

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

- `lib/tischlampe/audio/dyson.ex` — pure-Elixir port of the SWH "Dyson
  compressor" (LADSPA id 1403), faithful to
  `ladspa/dyson_compress_1403.xml` including the `f_pow2` exponent
  approximation. Matches the native plugin within ~2e-4. Parameters and
  defaults match the LADSPA ports: `peak_limit` (dB, -30..0, 0.0),
  `release_time` (s, 0..1, 0.0), `cfrate` (0..1, 0.5), `crate` (0..1, 0.5).
- `lib/tischlampe/audio/ffmpeg.ex` — probe/decode/encode via the ffmpeg
  executables. Decoding is raw f32le; encoding reuses the original
  container/codec and copies its metadata (`-map_metadata`).
- `lib/tischlampe/audio/waveform.ex` — peak envelopes with Nx.
- `lib/tischlampe/audio/master.ex` — streams a raw f32le file through one
  `Dyson` instance per channel, reporting progress per chunk; also writes
  the preview WAV slice.
- `lib/tischlampe/audio/player.ex` — preview playback through `mpv`
  (the webview cannot be trusted for audio output).

## Workflow (Session)

`lib/tischlampe/session.ex` is a singleton GenServer and the only place
that owns state:

1. `load/2` copies the uploaded file, then decodes + computes the original
   waveform in a task.
2. Mastering runs automatically in a task and is recomputed (debounced,
   400 ms) whenever parameters change, so **preview and render read the
   cached mastered PCM** and stay cheap.
3. `preview/0` plays 30 s starting at 30 % of the file; `render/0` writes
   `<name>_master.<ext>` into the output directory (default: `~/Music`,
   then `~/Downloads`, else the temp dir; override with
   `config :tischlampe, :output_dir`). Progress is broadcast on the
   `"qm:session"` PubSub topic.

## UI

- `lib/tischlampe_web/live/home_live.ex` — drop zone, rotary knobs with
  numeric inputs, original + mastered waveforms (inline SVG), preview and
  render buttons, progress bar.
- `priv/static/assets/js/app.js` is the pristine LiveView client copied
  from `deps/phoenix_live_view/priv/static/phoenix_live_view.js`.
- `priv/static/assets/js/quickmaster.js` boots LiveView and defines the
  `Knob` hook (pointer drag + arrow keys). Plain JS, no build step.
- `priv/static/assets/css/app.css` holds the outboard-compressor styling.

## Known limits

- The pure-Elixir DSP runs at roughly 100 k samples/s; a few minutes of
  stereo audio take on the order of a minute to master. It runs in the
  background with progress. Speeding this up would mean a NIF (the
  reference C is in `ladspa/`) or a rewrite in Nx.
- Membrane is intentionally not used: this is offline batch processing,
  so its streaming plugins would only add dependencies over plain file IO.
- The packaged release (`nix-build -A package`) needs `ffmpeg`/`mpv` on
  `PATH` at runtime.