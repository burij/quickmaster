# Changelog

## [0.9.1] — 2026-11-17

### Fixes
- Packaged app no longer aborts with `Settings schema
  'org.gtk.Settings.FileChooser' is not installed` when opening the file
  chooser. `GSETTINGS_SCHEMA_DIR` and `XDG_DATA_DIRS` were pointing at the
  schema *parent* instead of the directory holding `gschemas.compiled`
  (`…/gsettings-schemas/<pkg>/glib-2.0/schemas`). Both are now derived from
  `glib.getSchemaPath`. Only the packaged build was affected; the dev shell
  got the schemas from its environment.

## [0.9.0] — 2026-11-17 — First Beta

Desktop audio-mastering app: Phoenix LiveView in a native window (elixir-desktop, wxWebView on Linux).

### Features
- Open audio file — native GTK chooser (`FileDialog.open/0`)
- Dyson compressor — pure-Elixir port of SWH LADSPA 1403, four knobs + numeric inputs
- Pregain stage — auto-normalize to 0 dBFS (clamped 20 dB), toggle switch with amber LED
- Waveforms — original and mastered full waveforms (SVG)
- 30 s preview A/B — original vs mastered, separate play buttons
- Save — `_master` copy in original container/codec + metadata, native save dialog
- Background mastering with progress bar; preview-first phase order
- Multi-window — independent sessions via `Application.new_window/1`
- Headless CLI — `QUICKMASTER_HEADLESS=true mix quickmaster.cli`
- GNOME taskbar icon — `StartupWMClass=QuickmasterWindow` + `wxFrame.setName`
- Version single-sourced from `VERSION` file

### Fixes
- Encode preserves original codec + bitrate for lossy formats (MP3 no longer falls back to 128 kbps)
- Dark GTK title bar enforced (`GTK_THEME=Adwaita:dark`) in dev shell and built package
- Removed `opencode` from shell dependencies

### Known limits
- Pure-Elixir DSP is the bottleneck (~180 k samples/s mono)
- Sequential per-channel DSP (parallel was reverted due to artifacts)
- No HTML5 drag & drop on wxWebView/Linux; use **Open file…**
