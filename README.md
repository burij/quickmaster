# Quickmaster

Desktop audio-mastering app: Phoenix LiveView in a native window via
[elixir-desktop](https://github.com/elixir-desktop/desktop), on top of a
pure-Elixir port of the SWH "Dyson compressor" (LADSPA id 1403).

Open an audio file, adjust the four compressor knobs, compare the original
and the mastered 30-second preview A/B, then save a `_master` copy in the
original format and metadata.

## Run

```sh
nix-shell     # elixir, erlang, wxGTK32, ffmpeg, mpv, ...
run           # mix run --no-halt — the wx window opens
test          # ExUnit
make          # nix-build → result/bin/quickmaster
```

## How it works

- `ffmpeg` decodes and encodes every format; `mpv` plays the previews.
- The compressor is a pure-Elixir port, verified against the native plugin
  (see `ladspa/`).
- One `Quickmaster.Session` process owns the workflow and runs it in the
  background, **preview region first**, so audio is available long before a
  large file is fully processed.
- `Save` stays disabled until the full master is ready.

See **[AGENTS.md](AGENTS.md)** for architecture, conventions, gotchas and
known limits — read that first when picking the project up.
