---
title: Quickmaster — Technical Documentation
subtitle: A desktop audio mastering application built with Elixir, Phoenix LiveView, and wxWidgets
author: Quickmaster Team
date: 2026-10-18
label: Quickmaster · Technical Reference
abstract: This document provides a complete technical walkthrough of Quickmaster, a desktop audio mastering application that renders a Phoenix LiveView UI inside a native wxWidgets window. It covers architecture, DSP implementation, the mastering workflow, and the patterns used to bridge web and desktop technologies.
---

# Quickmaster — Technical Documentation

Quickmaster is a desktop audio mastering application. You open an audio file, adjust four Dyson compressor parameters, A/B the 30-second preview region against the original, and save a mastered copy that preserves the original container, codec, and metadata.

The application is written in Elixir. The UI is a Phoenix LiveView application rendered by **wxWebView** (WebKitGTK on Linux) inside a native window provided by **elixir-desktop**. There is no Electron, no Tauri, no Node.js — just the BEAM, a web engine, and a few system libraries (`ffmpeg`, `mpv`, `wxWidgets`).

This document explains how it works and, more importantly, the patterns you can reuse to build similar desktop applications with web technologies on the BEAM.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [The Desktop Bridge: elixir-desktop + wxWebView](#the-desktop-bridge-elixir-desktop--wxwebview)
3. [Application Supervision Tree](#application-supervision-tree)
4. [Session: The Single Source of Truth](#session-the-single-source-of-truth)
5. [Audio Pipeline](#audio-pipeline)
   - [FFmpeg Wrapper](#ffmpeg-wrapper)
   - [Dyson Compressor (Pure Elixir DSP)](#dyson-compressor-pure-elixir-dsp)
   - [Master: Streaming Multi-Channel Processing](#master-streaming-multi-channel-processing)
   - [Waveform Peaks](#waveform-peaks)
   - [Player: External mpv Process](#player-external-mpv-process)
6. [LiveView UI: HomeLive](#liveview-ui-homelive)
7. [File Dialogs: Native wxWidgets](#file-dialogs-native-wxwidgets)
8. [Nix Packaging: Reproducible Builds](#nix-packaging-reproducible-builds)
9. [Testing Strategy](#testing-strategy)
10. [Patterns You Can Steal](#patterns-you-can-steal)
11. [Pregain Stage (Auto-normalize to 0 dBFS)](#pregain-stage-auto-normalize-to-0-dbfs)
12. [CLI API & Headless Mode](#cli-api--headless-mode)

---

## Architecture Overview

### Layered View (Outside → In)

1. **Native Window** — `Desktop.Window` (wxWidgets frame)
2. **Web Engine** — `wxWebView` → WebKitGTK on Linux
3. **Phoenix LiveView** — `HomeLive` (knobs, waveforms, buttons, progress, file upload)
4. **WebSocket** — Phoenix Socket → `Phoenix.PubSub` topic `"qm:session"`
5. **Session GenServer** — Single source of truth, owns all mutable state
6. **Background Tasks** — One at a time, monitored (`spawn_monitor`)
7. **External Processes** — `ffmpeg` (decode/encode), `mpv` (preview playback)
8. **Pure-Elixir Libraries** — `Dyson` (DSP), `Waveform` (peak extraction)

### Data Flow

1. User action (knob turn, button click, file select) in HomeLive
2. LiveView sends `phx-click` / `phx-change` event to Session via cast/call
3. Session GenServer:
   - Updates state
   - Starts monitored background task if needed
   - Broadcasts changes via PubSub
4. Background task runs (`ffmpeg` decode, `Dyson` DSP, `Waveform` scan)
5. Task sends progress / done / error messages to Session
6. Session updates state, broadcasts via PubSub
7. LiveView receives broadcasts, updates UI optimistically

### Key Architectural Decisions

- **Single Session GenServer** — All mutable state lives in one process. No ETS, no Redis, no database. The BEAM's process isolation and PubSub make this both simple and correct.
- **Phase-based background work** — The mastering workflow is a deterministic state machine: `decode_preview → decode_full → master_preview → master_full`. One async task at a time, coordinated by a single `advance/1` function.
- **Preview-first** — The user hears audio within seconds. The 30 s preview window (at 30% into the track) is decoded and mastered before the full file.
- **Native feel** — File open uses HTML5 `<input type="file">` (handled by wxWebView's GTK file chooser). File save uses a native `wxFileDialog` via `elixir-desktop`.

---

## The Desktop Bridge: elixir-desktop + wxWebView

[elixir-desktop](https://github.com/elixir-desktop/desktop) is a thin wrapper around wxWidgets. On Linux it uses **wxWebView**, which embeds **WebKitGTK**. The Phoenix endpoint runs normally; `Desktop.Window` opens a native frame, loads the endpoint URL, and the LiveView connects over WebSocket.

```elixir
# lib/quickmaster/application.ex
defp window do
  if @start_window do
    [
      {Desktop.Window,
       [
         app: :quickmaster,
         id: QuickmasterWindow,
         title: "Quickmaster",
         icon: "static/images/icon.png",
         taskbar_icon: "static/images/icon.png",
         size: {1180, 840},
         min_size: {1000, 720},
         url: &QuickmasterWeb.Endpoint.url/0
       ]}
    ]
  else
    []
  end
end
```

**What you get for free:**
- Native window chrome, taskbar icon, menu bar (if you add one)
- WebKitGTK's HTML/CSS/JS engine (ES2022, WebGL, WebAudio — though we use external `mpv` for audio)
- GTK file chooser for `<input type="file">` — no drag-and-drop on Linux (GTK swallows it)

**What you must handle:**
- wx APIs need the **wx environment** in the calling process: `Desktop.Platform.Helpers.with_wx_env(fn -> ... end)`
- The WebKitGTK **WebProcess** (renderer) is a separate process — it doesn't inherit `GSETTINGS_SCHEMA_DIR`. You must also populate `XDG_DATA_DIRS` so the GTK file chooser schema is found. (See [Nix Packaging](#nix-packaging-reproducible-builds).)
- `Port.open({:spawn_executable, ...})` does **not** search `PATH`. Always resolve with `System.find_executable/1` first.

---

## Application Supervision Tree

```elixir
children = [
  QuickmasterWeb.Telemetry,
  {DNSCluster, query: ...},
  {Phoenix.PubSub, name: Quickmaster.PubSub},
  Quickmaster.Session,
  QuickmasterWeb.Endpoint
] ++ window()
```

- `Phoenix.PubSub` — The message bus. Session broadcasts `{:session, snapshot}`, `{:progress, phase, pct}`, `{:waveforms, ...}`, `{:playback, state}`.
- `Quickmaster.Session` — The singleton GenServer owning all state.
- `QuickmasterWeb.Endpoint` — Phoenix HTTP/WebSocket server.
- `Desktop.Window` — The native window (only in `:prod`/`:dev`, not `:test`).

**Why `DNSCluster`?** It's a lightweight cluster formation for distributed BEAM nodes. Not strictly needed for a single-window app, but harmless and useful if you later run multiple instances.

---

## Session: The Single Source of Truth

`Quickmaster.Session` is a `GenServer` registered under its own module name. It is the **only** process that holds mutable state. Everything else (LiveView, tasks, player) is stateless or derives from Session broadcasts.

### State Structure

```elixir
%{
  status: :empty | :loading | :mastering | :ready | :error,
  params: %{peak_limit: 0.0, release_time: 0.25, cfrate: 0.5, crate: 0.5},
  work_dir: "/tmp/quickmaster/...",
  input: %{path: "...", name: "track.wav", size: 12345, origin: :upload | :native},
  info: %{duration: 240.0, sample_rate: 44100, channels: 2, codec_name: "flac", ...},
  raw: "<<full decoded f32le PCM>>",
  preview_src: "<<30s preview f32le PCM>>",
  mastered: "<<full mastered f32le>>",
  mastered_preview: "<<30s mastered preview>>",
  preview_params: %{...},    # params used for mastered_preview
  mastered_params: %{...},   # params used for mastered
  orig_waveform: [[{min,max}], ...],     # 900 buckets, full track
  master_waveform: [[{min,max}], ...],
  orig_preview: [[{min,max}], ...],      # 320 buckets, 30s window
  master_preview: [[{min,max}], ...],
  percent: 0.0,
  phase: :decode_preview | :decode_full | :master_preview | :master_full | :encode,
  error: nil | "error message",
  output: nil | "/path/to/saved_master.wav",
  player: port() | nil,
  task: %{ref: ..., pid: ..., mon: ..., kind: ...} | nil,
  timer: timer_ref() | nil,
  pending: nil | {:preview, :original | :master} | {:render, :ask | "/path"}
}
```

### Public API

```elixir
Session.subscribe()                    # Subscribe calling process to PubSub
Session.snapshot()                     # Current state (no waveforms)
Session.waveforms()                    # Current waveforms
Session.load(temp_path, client_name)   # Uploaded file
Session.load_file(native_path)         # Native file (no copy)
Session.set_params(%{peak_limit: -6})  # Cast, debounced 400 ms
Session.preview(:original)             # Play original 30s preview
Session.preview(:master)               # Play mastered 30s preview
Session.stop_preview()
Session.render()                       # Open native save dialog
Session.render_to("/explicit/path.wav")# Direct save (tests)
Session.reset()                        # Clear everything
Session.default_params()               # Default parameter map
```

### The Phase Machine

`advance/1` is the **single decision step**. It runs whenever:
- A task finishes (`:task_done`, `:task_error`)
- Parameters change (debounced)
- A preview/render is requested and dependencies are ready

```elixir
defp advance(%{task: nil} = state) do
  cond do
    state.input == nil -> state                                    # Nothing loaded
    state.preview_src == nil -> start_task(state, :decode_preview) # 1. 30s decode
    state.raw == nil -> start_task(state, :decode_full)            # 2. Full decode
    not preview_current?(state) -> start_task(state, :master_preview) # 3. Preview master
    not mastered_current?(state) -> start_task(state, :master_full)   # 4. Full master
    match?({:preview, _}, state.pending) -> run_preview(...)       # Play preview
    match?({:render, _}, state.pending) -> run_render(...)         # Save file
    true -> state
  end
end
```

**Phase order rationale:** The 30 s preview at 30% into the track is decoded first (input seeking via `ffmpeg -ss before -i` — fast). The user can hit Play on the original preview while the full decode runs in background. Then the preview is mastered (fast), then the full track. `Save` only enables after phase 4 completes.

### Debounced Parameter Changes

When the user turns a knob, `Session.set_params/1` casts `{:set_params, params}`. The handler:
1. Stops any running master task (old parameters are stale)
2. Updates `state.params`
3. Schedules `advance` after 400 ms (`Process.send_after`)
4. If another change arrives within 400 ms, the timer resets

This prevents thrashing the DSP while the user is dragging a knob.

### Tasks: One at a Time, Monitored

Each phase runs in a separate `spawn_monitor` task. The Session holds `task: %{ref, pid, mon, kind}`.

```elixir
defp run_task(state, kind, fun) do
  parent = self()
  ref = make_ref()
  {pid, mon} = spawn_monitor(fn ->
    progress = fn phase, done, total -> send(parent, {:task_progress, ref, phase, done, total}) end
    try do
      send(parent, {:task_done, ref, kind, fun.(progress)})
    rescue e -> send(parent, {:task_error, ref, kind, Exception.format(:error, e, __STACKTRACE__)})
    end
  end)
  %{state | task: %{ref: ref, pid: pid, mon: mon, kind: kind}}
end
```

- Progress: `{:task_progress, ref, phase, done, total}` → broadcast `{:progress, phase, pct}`
- Success: `{:task_done, ref, kind, result}` → `finish/2` updates state, broadcasts, calls `advance`
- Failure: `{:task_error, ...}` → `fail/2` sets error, broadcasts
- Crash: `{:DOWN, mon, :process, pid, reason}` → clears task

**Why not `Task`/`Task.Supervisor`?** Explicit `spawn_monitor` gives full control over the monitor reference, the progress callback, and the cleanup logic. It's ~20 lines and zero dependencies.

---

## Audio Pipeline

All audio flows through **raw little-endian float32 PCM** (interleaved). This is the universal intermediate format: `ffmpeg` decodes to it, `Dyson` processes it, `ffmpeg` encodes from it.

### FFmpeg Wrapper

`Quickmaster.Audio.FFmpeg` wraps `ffmpeg`/`ffprobe` executables.

**Probe** — Returns structured info:
```elixir
%{
  duration: 240.5,
  sample_rate: 44100,
  channels: 2,
  codec_name: "flac",
  format_name: "flac",
  bits_per_raw_sample: 16,
  bits_per_sample: 16,
  sample_fmt: "s16",
  tags: %{"artist" => "...", "title" => "..."}
}
```

**Decode** — Streams to raw f32le. **Critical detail:** `-ss` (start time) is placed **before** `-i` (input). This is *input seeking* — ffmpeg seeks in the container before decoding, so a 30 s slice of a 2 GB file decodes in ~0.2 s instead of reading the whole file.

```elixir
args = ["-y", "-v", "error"] ++
  ["-ss", to_string(start)] ++          # before -i = input seeking
  ["-i", path, "-map", "0:a:0"] ++
  ["-t", to_string(duration)] ++        # duration limit
  ["-f", "f32le", "-acodec", "pcm_f32le", out]
```

**Encode** — Takes the mastered f32le, writes the **original container/codec** with **original metadata** (`-map_metadata 1`):

```elixir
args = [
  "-y", "-v", "error",
  "-f", "f32le", "-ar", sample_rate, "-ac", channels, "-i", raw,
  "-i", original,
  "-map", "0:a", "-map_metadata", "1"
] ++ codec_args ++ [out]
```

For WAV output, bit depth is preserved (16/24/32-bit integer or float). For other containers, ffmpeg picks the encoder from the extension.

**Executable resolution:** Configurable via `config :quickmaster, ffmpeg: "/path/to/ffmpeg"`, falls back to `System.find_executable/1`, then bare name.

### Dyson Compressor (Pure Elixir DSP)

`Quickmaster.Audio.Dyson` is a **sample-by-sample, mono** port of the SWH LADSPA plugin (ID 1403). The original C source is in `ladspa/dyson_compress_1403.xml`. The Elixir port is **faithful** — including the `f_pow2` fast exponent approximation (bit-twiddling on IEEE 754) and the fact that the plugin never sets `peaklimitdelay` (always 0).

**Parameters (matching LADSPA ports):**
| Parameter | Unit | Range | Default (Plugin) | Default (App) |
|-----------|------|-------|------------------|---------------|
| `peak_limit` | dB | -30..0 | 0.0 | 0.0 |
| `release_time` | s | 0..1 | 0.0 | **0.25** |
| `cfrate` (fast ratio) | — | 0..1 | 0.5 | 0.5 |
| `crate` (compression) | — | 0..1 | 0.5 | 0.5 |

**Why `release_time = 0.25`?** The plugin's nominal 0.0 makes the release filter extrapolate (divide by zero in the filter coefficient). 0.25 s is a musically sensible default.

**State struct:** Plain struct with fixed-size tuples for the two filter chains (`rlevelsqn` = 12 elements, `rlevelsqe` = 17 elements). The delay line uses `:queue` (amortized O(1) push/pop) instead of `:array` (copies ~1000 words per sample).

**Hot path:** `process_binary/2` iterates the binary with `for <<f::float-little-32 <- bin>>, reduce: ...`, calling `step/2` per sample. No allocations in the loop — state is a struct, tuples are updated functionally but the beam reuses memory efficiently.

**`f_pow2` approximation (from music-dsp):**
```elixir
defp f_pow2(x) do
  <<txi::signed-32>> = <<x - 0.5 + 12_582_912.0::float-32>>
  lx = txi - 0x4B400000
  dx = x - lx
  poly = 1.0 + dx * (@poly_a + dx * (@poly_b + dx * @poly_c))
  <<pi::signed-32>> = <<poly::float-32>>
  <<result::float-32>> = <<pi + (lx <<< 23)::signed-32>>
  result
end
```
This is **exactly** what the C plugin does. Verified against the compiled native plugin: max sample error < 5e-4.

**Performance:** ~180k samples/s/channel on a modern CPU. A 4 min stereo track takes ~2 minutes. The pure-Elixir DSP is the bottleneck. See [Patterns You Can Steal](#patterns-you-can-steal) for how to speed it up.

### Master: Streaming Multi-Channel Processing

`Quickmaster.Audio.Master.master_raw/6` streams an interleaved f32le file through one `Dyson` instance per channel.

```elixir
def master_raw(in_path, out_path, sample_rate, channels, params, progress \\ nil) do
  instances = List.duplicate(Dyson.new(sample_rate, params), channels) |> List.to_tuple()
  # ... open files, loop in chunks of 16384 frames ...
end
```

- **Chunk size:** 16384 frames (~0.37 s at 44.1 kHz). Bounded memory, progress callback per chunk.
- **Stereo fast path:** Specialized `process/3` for 1 and 2 channels (unrolled `for` comprehensions). N channels fall back to generic frame-by-frame loop.
- **Progress:** `progress.(bytes_done, total_bytes)` called after each chunk.

**Preview slice:** `Master.slice_to_wav/6` writes a 32-bit float WAV for the 30 s window (used by `mpv` playback).

### Waveform Peaks

`Quickmaster.Audio.Waveform.peaks/4` returns `[[{min, max}], ...]` per channel for drawing.

```elixir
def peaks(path, channels, buckets, range \\ nil) do
  # range = {from_frame, frames} or nil for whole file
  # Opens file once, does one binary pass per channel
  # Deliberately NOT Nx: Nx's BinaryBackend ~8 µs/element (50x slower)
end
```

- Reads file with `:file.pread/3` (random access, no seek syscall overhead)
- For each channel, scans its samples in the interleaved binary
- `if` instead of `min/max` BIFs in the hot loop (BIFs are slower here)
- 900 buckets for full waveform, 320 for 30 s preview

### Player: External mpv Process

WebKitGTK's audio output is unreliable in a headless/desktop context. `Quickmaster.Audio.Player` shells out to `mpv`:

```elixir
def play(path, opts \\ []) do
  exe = System.find_executable(mpv()) || mpv()
  args = ["--no-video", "--force-window=no", "--really-quiet"] ++
    option("--start", opts[:start]) ++
    option("--length", opts[:duration]) ++ [path]
  {:ok, Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args])}
end

def stop(port) do
  case Port.info(port, :os_pid) do
    {:os_pid, os_pid} -> System.cmd("kill", [to_string(os_pid)])
    _ -> :ok
  end
  Port.command(port, "q\n")  # mpv quit key
  Port.close(port)
end
```

- `Port.open({:spawn_executable, ...})` does not search PATH → resolve first
- Closing the port alone doesn't kill mpv reliably → signal by OS pid
- Session tracks the port, stops it on new preview/load/reset
- Broadcasts `{:playback, :original | :master | nil}` for UI play button state

---

## LiveView UI: HomeLive

`QuickmasterWeb.HomeLive` is a single LiveView. No router complexity — just `/`.

### Mount

```elixir
def mount(_params, _session, socket) do
  if connected?(socket), do: Session.subscribe()
  waves = Session.waveforms()

  {:ok,
   socket
   |> assign(:snap, Session.snapshot())
   |> assign(:param_defs, param_defs())
   |> assign(:waves, waves)
   |> assign(:playback, nil)
   |> assign(:ffmpeg?, FFmpeg.available?())
   |> allow_upload(:audio,
     accept: :any,
     max_entries: 1,
     max_file_size: 4_000_000_000,  # 4 GB
     chunk_size: 1_000_000,
     auto_upload: true,
     progress: &handle_progress/3
   )}
end
```

- `connected?(socket)` guard: only subscribe on mount (not on static render)
- `Session.waveforms()` called explicitly — waveforms are only *broadcast* on change, so a late-joining LiveView would otherwise render empty
- Upload config: `progress: &handle_progress/3` (not a callback on the config — a common LiveView 1.2 gotcha)

### Event Handlers

| Event | Action |
|-------|--------|
| `"param"` | Validate, clamp, `Session.set_params/1` |
| `"reset"` | `Session.set_params(Session.default_params())` |
| `"preview"` | `Session.preview(:original \| :master)` |
| `"stop_preview"` | `Session.stop_preview()` |
| `"render"` | `Session.render()` |

### Upload Handling

```elixir
def handle_progress(:audio, entry, socket) do
  if entry.done? do
    consume_uploaded_entries(socket, :audio, fn %{path: path}, entry ->
      Session.load(path, entry.client_name)
      {:ok, entry.client_name}
    end)
    {:noreply, socket}
  else
    {:noreply, socket}
  end
end
```

- Progress is on `entry.progress` (not on the config — another LiveView 1.2 gotcha)
- `consume_uploaded_entries` moves the temp file into the session's work dir

### Broadcast Handling

```elixir
def handle_info({:session, snap}, socket), do: {:noreply, assign(socket, :snap, snap)}
def handle_info({:progress, phase, percent}, socket) do
  {:noreply, assign(socket, :snap, %{socket.assigns.snap | percent: percent, phase: phase})}
end
def handle_info({:waveforms, waves}, socket), do: {:noreply, assign(socket, :waves, waves)}
def handle_info({:playback, state}, socket), do: {:noreply, assign(socket, :playback, state)}
```

Optimistic UI: progress updates apply immediately to the progress bar.

### Components

The HEEx template uses function components (`<.knob>`, `<.wave>`, `<.preview_wave>`, `<.file_panel>`). No separate component modules — everything in one file for simplicity.

**Knob component:** SVG circle + line indicator, driven by the `Knob` JS hook (`priv/static/assets/js/quickmaster.js`). Pointer drag + arrow keys. Also a numeric `<input type="number">` form that sends `"param"` events.

**Waveform rendering:** SVG polygons. `wave_points/3` converts `[{min, max}]` buckets to polygon point strings. Two polygons per channel (upper/lower envelope) for the filled look.

---

## File Dialogs: Native wxWidgets

`Quickmaster.FileDialog.save/1` opens a native `wxFileDialog` (Save style with overwrite prompt).

```elixir
defp show(options) do
  Desktop.Platform.Helpers.with_wx_env(fn ->
    frame = Desktop.Window.frame(QuickmasterWindow)
    dialog = :wxFileDialog.new(frame, options)
    result = :wxFileDialog.showModal(dialog)
    path = if result == @ok, do: List.to_string(:wxFileDialog.getPath(dialog))
    :wxFileDialog.destroy(dialog)
    path
  end)
rescue e -> Logger.error(...); nil
end
```

**Critical:** `Desktop.Platform.Helpers.with_wx_env/1` — wx APIs need the wx environment in the *calling* process. Without it: `ErlangError {:wx, :unknown_env}`.

**Open dialog:** Currently uses HTML5 `<input type="file">` (handled by wxWebView's GTK file chooser). A native open dialog (`FileDialog.open/0`) would avoid the websocket upload copy for large files — see [Backlog](#backlog).

---

## Nix Packaging: Reproducible Builds

The project uses a `lib.nix` that defines both a development shell and a production package.

### Development Shell (`nix-shell`)

```nix
shell = pkgs.mkShell {
  buildInputs = elixirEnv ++ dependencies;
  shellHook = ''
    alias run='mix run --no-halt'
    alias test='./result/bin/quickmaster start'
    alias make='rm result; nix-build'
    # ...
  '';
};
```

Provides: `elixir`, `erlang`, `wxWidgets_3_2`, `ffmpeg-headless`, `mpv`, `inotify-tools`, `nixpkgs-fmt`, `git`, `wget`.

The shellHook exports `GTK_THEME=Adwaita:dark` so the title bar stays dark even in a light system theme.

### Production Package

```nix
release = beamPackages.mixRelease {
  pname = "quickmaster";
  version = "0.1";
  src = ./.;
  removeCookie = false;
};

runtimePath = pkgs.lib.makeBinPath (with pkgs; [
  ffmpeg-headless
  mpv
  wxwidgets_3_2
  gtk3                    # ← WebKitGTK backend needs GTK3 libs
]);

# GSettings schema directory for GTK file chooser
gsettingsSchemaDir = pkgs.lib.makeSearchPath "share/gsettings-schemas" (with pkgs; [gtk3]);

# XDG_DATA_DIRS for WebKitGTK WebProcess (renderer)
gtkSchemaDir = "${pkgs.gtk3}/share/gsettings-schemas/gtk+3-3.24.52";
desktopSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/gsettings-desktop-schemas-50.1";
xdgDataDirs = "${gtkSchemaDir}:${desktopSchemaDir}";

package = pkgs.runCommand "quickmaster" { nativeBuildInputs = [pkgs.makeWrapper]; } ''
  mkdir -p $out/bin
  makeWrapper ${release}/bin/quickmaster $out/bin/quickmaster \
    --prefix PATH : ${runtimePath} \
    --set GSETTINGS_SCHEMA_DIR ${gsettingsSchemaDir} \
    --prefix XDG_DATA_DIRS : ${xdgDataDirs} \
    --set GTK_THEME Adwaita:dark
'';
```

**Why these environment variables?**

| Variable | Purpose |
|----------|---------|
| `PATH` | `ffmpeg`, `mpv`, `wxWidgets` binaries |
| `GSETTINGS_SCHEMA_DIR` | Main process finds `org.gtk.Settings.FileChooser` schema |
| `XDG_DATA_DIRS` | **WebKitGTK WebProcess** finds schemas (doesn't inherit `GSETTINGS_SCHEMA_DIR`) |

The WebProcess is a separate process spawned by WebKitGTK. It uses the standard XDG lookup: `$XDG_DATA_DIRS/glib-2.0/schemas/`. The GTK3 schemas live at `share/gsettings-schemas/gtk+3-3.24.52/glib-2.0/schemas/gschemas.compiled`. So `XDG_DATA_DIRS` must include the **parent directory** containing `glib-2.0/schemas/`.

**Build command:** `make` (defined as `rm result; nix-build` in shell hook). Output: `result/bin/quickmaster`.

### Desktop Integration

The package installs a standard `.desktop` file and icon so the application appears in application launchers (GNOME, KDE, etc.):

```nix
nativeBuildInputs = [ pkgs.makeWrapper pkgs.desktop-file-utils ];

mkdir -p $out/share/applications
cat > $out/share/applications/${appName}.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Quickmaster
GenericName=Audio Mastering
Comment=Fast audio mastering with Dyson compressor
Exec=quickmaster start
Icon=quickmaster
Terminal=false
Categories=AudioVideo;AudioEditing;
StartupNotify=true
EOF

mkdir -p $out/share/icons/hicolor/256x256/apps
cp ${./priv/static/images/icon.png} $out/share/icons/hicolor/256x256/apps/${appName}.png
```

**Resulting paths:**
- `$out/share/applications/quickmaster.desktop`
- `$out/share/icons/hicolor/256x256/apps/quickmaster.png`

When installed via `callPackage` in NixOS, the app appears in the application menu with the correct icon.

---

## Testing Strategy

Tests live in `test/` and use `ExUnit`. Key properties:

- **Tagged external dependencies:** `@moduletag :ffmpeg` and `:mpv` — skipped when tools not on PATH (CI runs in nix-shell where they exist).
- **Session tests are `async: false`** — Session is a singleton, tests call `Session.reset()` in `setup`.
- **Dyson test validates against native plugin:** Fixtures in `test/fixtures/dyson/` were generated by compiling the C LADSPA plugin and running it on deterministic input. The test compares Elixir output byte-for-byte (max error < 5e-4).
- **LiveView tests** use `Phoenix.LiveViewTest` — test uploads, knob interactions, progress labels, save button enable/disable.

Run: `mix test` (inside `nix-shell`).

---

## Patterns You Can Steal

### 1. Single GenServer + PubSub for Desktop State

```elixir
# One process owns all state. Others subscribe.
def subscribe, do: Phoenix.PubSub.subscribe(MyApp.PubSub, "my:topic")

def handle_info({:session, snap}, socket), do: {:noreply, assign(socket, :snap, snap)}
```

No Redux, no Context, no state management library. The BEAM *is* the state management.

### 2. Deterministic Phase Machine with `advance/1`

```elixir
defp advance(%{task: nil} = state) do
  cond do
    state.step1 == nil -> start_task(state, :step1)
    state.step2 == nil -> start_task(state, :step2)
    state.pending == {:action, arg} -> do_action(state, arg)
    true -> state
  end
end
```

One function decides what happens next. Easy to read, easy to test, no race conditions.

### 3. Debounced Casts for UI Parameters

```elixir
def handle_cast({:set_params, params}, state) do
  state = stop_task(state)
  state = %{state | params: params}
  broadcast_session(state)
  {:noreply, schedule_advance(state)}
end

defp schedule_advance(state) do
  if state.timer, do: Process.cancel_timer(state.timer)
  %{state | timer: Process.send_after(self(), :advance, 400)}
end
```

### 4. Monitored Tasks with Progress Callback

```elixir
defp run_task(state, kind, fun) do
  parent = self()
  ref = make_ref()
  {pid, mon} = spawn_monitor(fn ->
    progress = fn phase, done, total -> send(parent, {:task_progress, ref, phase, done, total}) end
    try do
      send(parent, {:task_done, ref, kind, fun.(progress)})
    rescue e -> send(parent, {:task_error, ref, kind, format_error(e)})
    end
  end)
  %{state | task: %{ref: ref, pid: pid, mon: mon, kind: kind}}
end
```

No `Task` supervisor, no `GenStage`. Just `spawn_monitor` and message passing.

### 5. Stream Large Files with `:file.pread/3`

```elixir
{:ok, fd} = :file.open(path, [:read, :binary, :raw])
# later, for each chunk:
{:ok, bin} = :file.pread(fd, offset, byte_count)
```

Random access without seek syscalls. Used by waveform scanner and preview slice.

### 6. Pure-Elixir DSP with Unrolled Loops

```elixir
defp scan_hold(t, n0, r) do
  r1 = 1.0 - r
  o1 = elem(t, 1)
  p1 = if n0 > o1, do: n0, else: n0 * r + o1 * r1
  o2 = elem(t, 2)
  p2 = if p1 > o2, do: p1, else: p1 * r + o2 * r1
  # ... unrolled 12 times ...
  {{n0, p1, p2, ...}, p11}
end
```

Fixed-size tuples + explicit unrolling = no heap allocation in hot loop. The BEAM optimizes this well.

### 7. `f_pow2` Fast Exponent for DSP

```elixir
defp f_pow2(x) do
  <<txi::signed-32>> = <<x - 0.5 + 12_582_912.0::float-32>>
  lx = txi - 0x4B400000
  dx = x - lx
  poly = 1.0 + dx * (@poly_a + dx * (@poly_b + dx * @poly_c))
  <<pi::signed-32>> = <<poly::float-32>>
  <<result::float-32>> = <<pi + (lx <<< 23)::signed-32>>
  result
end
```

Bit-twiddling on IEEE 754. 10-20x faster than `:math.pow/2`. Use when you need `exp2(x)` in a tight loop.

### 8. Native Dialogs via `with_wx_env`

```elixir
Desktop.Platform.Helpers.with_wx_env(fn ->
  frame = Desktop.Window.frame(MyWindow)
  dialog = :wxFileDialog.new(frame, options)
  # ...
end)
```

Any wxWidgets call must run inside this wrapper.

### 9. Executable Resolution (Not PATH in Ports)

```elixir
defp ffmpeg, do: Application.get_env(:myapp, :ffmpeg) || System.find_executable("ffmpeg") || "ffmpeg"

def run(exe, args) do
  case System.cmd(exe, args) do
    {out, 0} -> {:ok, out}
    {out, code} -> {:error, {:cmd, code, out}}
  end
rescue e in ErlangError -> {:error, e}
end
```

`Port.open({:spawn_executable, ...})` does not search PATH. Always resolve first.

### 10. WebKitGTK WebProcess Needs `XDG_DATA_DIRS`

```nix
xdgDataDirs = "${gtk3}/share/gsettings-schemas/gtk+3-3.24.52}:${gsettings-desktop-schemas}/share/gsettings-schemas/gsettings-desktop-schemas-50.1";
# In wrapper: --prefix XDG_DATA_DIRS : ${xdgDataDirs}
```

The renderer process doesn't inherit `GSETTINGS_SCHEMA_DIR`. It uses XDG. Point it at directories containing `glib-2.0/schemas/`.

---

---

## Pregain Stage (Auto-normalize to 0 dBFS)

The Pregain stage is a pre-compressor gain normalization that runs **before** the Dyson compressor. It ensures quiet tracks reach 0 dBFS peak level without excessive boosting.

### Algorithm

1. **Peak scan** — Full decoded audio is scanned for the absolute peak sample per channel
2. **Gain computation** — Linear gain = `1.0 / peak`, clamped to `max_db` (default 20 dB)
3. **Application** — Gain applied per channel during mastering pass

### Parameters

| Parameter | Unit | Range | Default | Description |
|-----------|------|-------|---------|-------------|
| `pregain_enabled` | boolean | true/false | `true` | Enable/disable pregain |
| `pregain_max_db` | dB | 0..40 | `20.0` | Maximum gain ceiling |

### Integration

- Added as first pass in `Master.master_raw/6` when `pregain_enabled: true`
- Two-pass: scan peaks → apply gains + Dyson in streaming fashion
- Chunked processing (16,384 frames) keeps memory bounded
- Parameter change triggers full re-master (preview → full)

### UI

Located in its own panel below the Dyson compressor:
- **Old-school horizontal toggle switch** — metallic thumb, I/O labels in amber
- **Amber LED** — glows when active
- Label: "Auto-normalize to 0 dBFS"
- Hint: "Clamped to 20 dB max gain"

---

## CLI API & Headless Mode

Quickmaster provides a command-line interface for programmatic control and CI/CD integration. Works in both GUI and headless modes.

### Headless Mode

Set `QUICKMASTER_HEADLESS=true` to run without opening a native window:

```bash
QUICKMASTER_HEADLESS=true mix quickmaster.cli <command>
```

### Commands

| Command | Description |
|---------|-------------|
| `load <path>` | Load audio file |
| `set <param> <value>` | Set parameter (e.g., `peak_limit -6.0`) |
| `get <param>` | Get current parameter value |
| `params` | Show all parameters |
| `toggle-pregain` | Toggle pregain stage |
| `preview [source]` | Play preview (`original` or `master`, default `master`) |
| `stop-preview` | Stop playback |
| `render <path>` | Render mastered file |
| `status` | Show session status |
| `reset` | Reset to default parameters |
| `wait-ready` | Block until mastering complete |
| `test <path>` | Run full test sequence (load → wait → set params → toggle pregain) |

### Example: Full Test Sequence

```bash
QUICKMASTER_HEADLESS=true \
  mix quickmaster.cli test testfiles/track.wav
```

This loads the file, waits for mastering, sets `peak_limit: -6.0`, toggles pregain off/on, and verifies all phases complete.

### Programmatic Usage (Elixir)

```elixir
Quickmaster.CLI.load_file("track.wav")
Quickmaster.CLI.wait_until_ready()
Quickmaster.CLI.set_param(:peak_limit, -6.0)
Quickmaster.CLI.toggle_pregain()
Quickmaster.CLI.render("output_master.wav")
```

### Version Management

Version is single-sourced from `VERSION` file:

```bash
# Update version
echo "0.9.0" > VERSION
```

Both `mix.exs` and `lib.nix` read from this file automatically.

---

## Backlog (From AGENTS.md)

1. **DSP Speed** — NIF from `ladspa/` C source (~50x faster) or per-channel `Task`s (~2x).
2. **Native Open Dialog** — Re-add `FileDialog.open/0` (like `save/1`), call `Session.load_file/1`.
3. **Configurable Preview Window** — Currently hardcoded 30 s / 30% (`@preview_seconds`, `@preview_ratio`).
4. **Remember Save Directory** — Currently suggests next to opened file or `~/Music`.
5. **Drag & Drop** — Would need wxWidgets patch (`gtk_drag_dest_unset`) — out of scope.

---

## Appendix: Project Structure

```
.
├── AGENTS.md              # Handoff notes (this document's source of truth)
├── DOCS.md                # This file
├── README.md              # User-facing README
├── lib.nix                # Nix shell + package definition
├── shell.nix              # Entry point for nix-shell
├── mix.exs                # Elixir project config
├── config/                # Phoenix config (minimal)
├── lib/
│   ├── quickmaster/
│   │   ├── application.ex      # OTP app + Desktop.Window
│   │   ├── session.ex          # Singleton GenServer (core logic)
│   │   ├── file_dialog.ex      # Native wxFileDialog
│   │   └── audio/
│   │       ├── dyson.ex        # Pure-Elixir Dyson compressor
│   │       ├── ffmpeg.ex       # ffmpeg/ffprobe wrapper
│   │       ├── master.ex       # Streaming multi-channel mastering
│   │       ├── waveform.ex     # Peak envelope extraction
│   │       └── player.ex       # mpv playback
│   └── quickmaster_web/
│       ├── endpoint.ex         # Phoenix endpoint + Desktop.Auth
│       ├── router.ex           # Single live "/" route
│       ├── live/
│       │   └── home_live.ex    # Main LiveView (UI + events)
│       └── components/         # Layouts, core components (scaffold)
├── priv/static/
│   ├── assets/js/quickmaster.js    # Knob hook (drag + arrows)
│   ├── assets/css/app.css          # Styling
│   └── images/                     # Logo, favicon, icon.png
├── test/
│   ├── test_helper.exs
│   ├── quickmaster/
│   │   ├── audio/dyson_test.exs      # Validates against native plugin
│   │   ├── audio/pipeline_test.exs   # ffmpeg decode/slice/encode
│   │   └── session_test.exs          # Phase order, render, preview
│   └── quickmaster_web/
│       └── live/home_live_test.exs   # UI interactions
├── testfiles/              # Test audio fixtures
└── ladspa/                 # Upstream SWH plugin source (reference for Dyson)
```

---

## Appendix: Key Dependencies

| Dependency | Purpose |
|------------|---------|
| `phoenix`, `phoenix_live_view` | Web framework + LiveView |
| `desktop` (elixir-desktop) | Native window + wxWebView |
| `bandit` | HTTP server (replaces Cowboy) |
| `jason` | JSON for ffprobe output |
| `dns_cluster` | Distributed clustering (optional) |
| `ffmpeg` (system) | Decode/encode any audio format |
| `mpv` (system) | Preview playback |
| `wxWidgets 3.2` (system) | Native window + WebKitGTK |
| `gtk3` (system) | WebKitGTK backend + file chooser schemas |

---

## Appendix: Configuration

```elixir
# config/runtime.exs (or config/config.exs)
config :quickmaster,
  ffmpeg: "/usr/bin/ffmpeg",      # optional override
  ffprobe: "/usr/bin/ffprobe",    # optional override
  mpv: "/usr/bin/mpv",            # optional override
  output_dir: "/home/user/Music", # optional save directory
  dns_cluster_query: :ignore      # clustering
```

All optional. Sensible defaults via `System.find_executable/1` and `System.user_home/0`.

---

*This documentation was generated from the source code as of commit on 2026-10-18. For the latest code, see the repository.*
<!-- TYPRESS-PROJECT
{"v":1,"settings":{"titleStyle":"cover","bodyFont":"plexsans","lh":1.5,"align":"left","hyphLevel":"few","ink":"#1e293b","liga":false,"headColor":"#0f172a","h2":13,"h3":11,"h4":9.6,"h4Italic":false,"h1Break":"page","numbering":true,"numColor":"#2446c8","headL":"{title}","headR":"{section}","footC":"","footR":"{page}","hfRule":"head","tblStyle":"grid","tStripe":true,"thBg":"#eef2ff","thFill":true,"codeSize":8.4,"codeBg":"#f6f8fa","codeBorder":"#e5e7eb","codeKw":"#7c3aed","codeInlineBg":true,"capFont":"head","autoToc":true,"tocDepth":3},"templateId":"technik","customTemplates":[],"fonts":["plexsans","plexmono"],"images":{}}
-->
