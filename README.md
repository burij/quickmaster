# Quickmaster

A desktop audio-mastering app: Phoenix LiveView running in a native window
via [elixir-desktop](https://github.com/elixir-desktop/desktop).

Open an audio file via **File → Open audio file…**, tweak the Dyson
compressor, listen to a 30-second preview and render a `_master` copy in
the original format and metadata (you pick the target with a save dialog).

## Run

```sh
nix-shell            # provides elixir, wxGTK32, ffmpeg, mpv, ...
run                  # mix run --no-halt — the window opens
```

`test` runs the ExUnit suite. `make` builds the Nix release
(`result/bin/quickmaster`).

## How it works

- The compressor is a pure-Elixir port of the SWH "Dyson compressor"
  (LADSPA id 1403), verified against the native plugin.
- `ffmpeg` decodes and encodes every format; `mpv` plays the preview.
- The master is computed in the background whenever settings change, so
  preview and render are instant.

See `AGENTS.md` for the project layout and known limits.
