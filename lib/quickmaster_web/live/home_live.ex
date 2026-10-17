defmodule QuickmasterWeb.HomeLive do
  @moduledoc """
  Quickmaster home screen: open an audio file, tweak the Dyson compressor,
  A/B the 30 s previews and save a `_master` copy.
  """

  use QuickmasterWeb, :live_view

  alias Quickmaster.Audio.FFmpeg
  alias Quickmaster.Session

  # {key, label, unit, min, max, step, decimals}
  @params [
    {:peak_limit, "Peak limit", "dB", -30.0, 0.0, 0.5, 2},
    {:release_time, "Release time", "s", 0.0, 1.0, 0.01, 2},
    {:cfrate, "Fast ratio", "", 0.0, 1.0, 0.01, 2},
    {:crate, "Compression", "", 0.0, 1.0, 0.01, 2}
  ]

  @impl true
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
       max_file_size: 4_000_000_000,
       chunk_size: 1_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("param", %{"name" => name, "value" => value}, socket) do
    with {:ok, key, min, max, step} <- param_meta(name),
         {v, _} <- Float.parse(value) do
      params = Map.put(socket.assigns.snap.params, key, clamp(v, min, max, step))
      Session.set_params(params)
      {:noreply, assign(socket, :snap, %{socket.assigns.snap | params: params})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    Session.set_params(Session.default_params())
    {:noreply, socket}
  end

  def handle_event("preview", %{"source" => "original"}, socket) do
    Session.preview(:original)
    {:noreply, socket}
  end

  def handle_event("preview", _params, socket) do
    Session.preview(:master)
    {:noreply, socket}
  end

  def handle_event("stop_preview", _params, socket) do
    Session.stop_preview()
    {:noreply, socket}
  end

  def handle_event("render", _params, socket) do
    Session.render()
    {:noreply, socket}
  end

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

  @impl true
  def handle_info({:session, snap}, socket), do: {:noreply, assign(socket, :snap, snap)}

  def handle_info({:progress, phase, percent}, socket) do
    snap = %{socket.assigns.snap | percent: percent, phase: phase}
    {:noreply, assign(socket, :snap, snap)}
  end

  def handle_info({:waveforms, waves}, socket), do: {:noreply, assign(socket, :waves, waves)}

  def handle_info({:playback, state}, socket), do: {:noreply, assign(socket, :playback, state)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="qm-app">
      <header class="qm-header">
        <div class="qm-brand">
          <img src={~p"/images/logo.svg"} alt="" class="qm-logo" width="34" height="34" />
          <span class="qm-title">Quickmaster</span>
        </div>
        <div class="qm-subtitle">fast audio mastering · Dyson compressor</div>
      </header>

      <div :if={not @ffmpeg?} class="qm-alert">
        ffmpeg was not found on PATH. Install it (the project shell provides it) and restart.
      </div>

      <div class="qm-main">
        <.file_panel snap={@snap} uploads={@uploads} />

        <div class="qm-panel qm-controls">
          <div class="qm-panel-title">Dyson compressor</div>
          <div class="qm-knobs">
            <.knob
              :for={{key, label, unit, min, max, step, dec} <- @param_defs}
              name={key}
              label={label}
              unit={unit}
              min={min}
              max={max}
              step={step}
              decimals={dec}
              value={Map.get(@snap.params, key)}
            />
          </div>
          <div class="qm-control-actions">
            <button type="button" class="qm-btn" phx-click="reset">Reset</button>
          </div>
        </div>

        <div class="qm-panel qm-waves">
          <div class="qm-panel-title">Waveform</div>
          <div :if={@snap.file == nil} class="qm-empty">
            No file loaded — use the Open file… button
          </div>
          <.wave label="Original" peaks={@waves.original} kind="orig" />
          <.wave label="Mastered" peaks={@waves.mastered} kind="master" />
        </div>

        <div class="qm-panel qm-render">
          <div :if={working?(@snap)} class="qm-progress">
            <div class="qm-progress-label">
              {phase_label(@snap.phase)}
              <span :if={determinate?(@snap.phase)}>{round(@snap.percent)}%</span>
            </div>
            <div class="qm-bar" class={not determinate?(@snap.phase) && "qm-bar-indeterminate"}>
              <div class="qm-bar-fill" style={"width: #{@snap.percent}%"}></div>
            </div>
          </div>

          <div :if={@snap.stale and @snap.status == :ready} class="qm-hint">
            Settings changed — the master is being recomputed.
          </div>

          <div class="qm-render-row">
            <.preview_wave
              :if={@waves.original_preview}
              label="Original · 30 s"
              peaks={@waves.original_preview}
              kind="orig"
              source="original"
              playing={@playback == :original}
            />

            <.preview_wave
              :if={@waves.mastered_preview}
              label="Mastered · 30 s"
              peaks={@waves.mastered_preview}
              kind="master"
              source="master"
              playing={@playback == :master}
            />

            <div
              :if={@waves.original_preview && @waves.mastered_preview == nil}
              class="qm-mini qm-mini-pending"
            >
              mastering…
            </div>

            <button
              id="qm-save"
              type="button"
              class="qm-btn qm-btn-render qm-save"
              phx-click="render"
              disabled={not save_ready?(@snap)}
            >
              <span :if={save_waiting?(@snap)} class="qm-spinner qm-spinner-sm"></span>
              <span>⬇ Save</span>
            </button>
          </div>

          <div :if={@snap.output} class="qm-output">
            Saved: <code>{@snap.output}</code>
          </div>
          <div :if={@snap.error} class="qm-alert">{@snap.error}</div>
        </div>
      </div>
    </div>
    """
  end

  ## components

  attr :snap, :map, required: true
  attr :uploads, :map, required: true

  defp file_panel(assigns) do
    ~H"""
    <div class="qm-panel qm-file">
      <div class="qm-file-info">
        <div :if={@snap.file} class="qm-file-name" title={@snap.file.name}>
          {@snap.file.name}
        </div>
        <div :if={@snap.file == nil} class="qm-file-name qm-dim">No file loaded</div>

        <div :if={@snap.file} class="qm-file-meta">
          <span>{format_duration(@snap.file.duration)}</span>
          <span>{@snap.file.channels} ch</span>
          <span>{@snap.file.sample_rate} Hz</span>
          <span>{format_size(@snap.file.size)}</span>
        </div>
        <div :if={@snap.file == nil} class="qm-file-meta">
          open a file to start
        </div>
      </div>

      <div class="qm-file-actions">
        <!-- fixed-size slot so the button does not shift while busy -->
        <div class="qm-spinner-slot">
          <span :if={busy?(@uploads, @snap)} class="qm-spinner" aria-label="Working"></span>
        </div>
        <form id="qm-upload" phx-change="validate" phx-submit="validate">
          <label class="qm-btn qm-btn-ghost" phx-drop-target={@uploads.audio.ref}>
            Open file…
            <.live_file_input upload={@uploads.audio} id="qm-input" class="qm-file-input" />
          </label>
        </form>
      </div>
    </div>
    """
  end

  attr :name, :atom, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :min, :float, required: true
  attr :max, :float, required: true
  attr :step, :float, required: true
  attr :decimals, :integer, required: true
  attr :value, :float, required: true

  defp knob(assigns) do
    ~H"""
    <div class="qm-knob-wrap">
      <div
        class="qm-knob"
        id={"knob-" <> Atom.to_string(@name)}
        phx-hook="Knob"
        role="slider"
        tabindex="0"
        aria-label={@label}
        aria-valuemin={@min}
        aria-valuemax={@max}
        data-name={@name}
        data-min={@min}
        data-max={@max}
        data-step={@step}
        data-value={@value}
        data-decimals={@decimals}
      >
        <svg viewBox="0 0 100 100" class="qm-knob-svg">
          <circle class="qm-knob-base" cx="50" cy="50" r="45" />
          <circle class="qm-knob-track" cx="50" cy="50" r="45" />
          <line class="qm-knob-indicator" x1="50" y1="26" x2="50" y2="10" />
        </svg>
        <span class="qm-knob-value">{num(@value, @decimals)}</span>
      </div>
      <div class="qm-knob-label">{@label}</div>
      <div class="qm-knob-unit">{@unit}</div>
      <form
        id={"num-" <> Atom.to_string(@name)}
        phx-change="param"
        class="qm-knob-number"
      >
        <input
          type="number"
          name="value"
          phx-value-name={@name}
          value={num(@value, @decimals)}
          min={@min}
          max={@max}
          step={@step}
        />
      </form>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :peaks, :list, default: nil
  attr :kind, :string, required: true

  defp wave(assigns) do
    ~H"""
    <div class="qm-wave">
      <div class="qm-wave-label">{@label}</div>
      <svg class="qm-wave-svg" viewBox="0 0 1000 120" preserveAspectRatio="none">
        <line class="qm-wave-mid" x1="0" y1="60" x2="1000" y2="60" />
        <polygon
          :for={{peaks, i} <- Enum.with_index(@peaks || [])}
          points={wave_points(peaks, 1000, 120)}
          class={"qm-wave-fill qm-wave-#{@kind} qm-wave-ch#{i}"}
        />
      </svg>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :peaks, :list, required: true
  attr :kind, :string, required: true
  attr :source, :string, required: true
  attr :playing, :boolean, required: true

  # Small waveform of the 30 s preview region, with a play button laid over
  # its left edge so original and master can be compared A/B.
  defp preview_wave(assigns) do
    ~H"""
    <div class="qm-mini">
      <div class="qm-mini-head">
        <span class={"qm-mini-label qm-mini-label-#{@kind}"}>{@label}</span>
      </div>
      <div class="qm-mini-body">
        <svg class="qm-mini-svg" viewBox="0 0 600 70" preserveAspectRatio="none">
          <polygon
            :for={{peaks, i} <- Enum.with_index(@peaks)}
            points={wave_points(peaks, 600, 70)}
            class={"qm-wave-fill qm-wave-#{@kind} qm-wave-ch#{i}"}
          />
        </svg>
        <button
          type="button"
          class="qm-mini-play"
          phx-click={if(@playing, do: "stop_preview", else: "preview")}
          phx-value-source={@source}
          title={if(@playing, do: "Stop", else: "Play")}
        >
          {if @playing, do: "■", else: "▶"}
        </button>
      </div>
    </div>
    """
  end

  ## helpers

  defp wave_points(peaks, w, h) do
    n = length(peaks)
    mid = h / 2
    scale = h / 2

    up =
      peaks
      |> Enum.with_index()
      |> Enum.map(fn {{_lo, hi}, i} -> point(i, n, w, mid - hi * scale) end)

    down =
      peaks
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.map(fn {{lo, _}, i} -> point(i, n, w, mid - lo * scale) end)

    Enum.join(up ++ down, " ")
  end

  defp point(i, n, w, y) do
    x = if n > 1, do: i / (n - 1) * w, else: 0.0
    "#{Float.round(x * 1.0, 2)},#{Float.round(y * 1.0, 2)}"
  end

  # Busy while an upload is running or the file is being decoded.
  defp busy?(uploads, snap) do
    upload_progress(uploads.audio) != nil or snap.status == :loading
  end

  # Aggregate upload progress; it lives on the entries, not on the config.
  defp upload_progress(%{entries: []}), do: nil

  defp upload_progress(%{entries: entries}) do
    if Enum.all?(entries, & &1.done?) do
      nil
    else
      div(Enum.sum(Enum.map(entries, & &1.progress)), length(entries))
    end
  end

  # The master must be complete before it can be saved.
  defp save_ready?(snap) do
    snap.file != nil and snap.status == :ready and not snap.stale
  end

  defp param_defs, do: @params

  defp param_meta(name) do
    case Enum.find(@params, fn {key, _, _, _, _, _, _} -> Atom.to_string(key) == name end) do
      {key, _label, _unit, min, max, step, _dec} -> {:ok, key, min, max, step}
      nil -> :error
    end
  end

  defp clamp(v, min, max, step) do
    v |> Kernel.max(min) |> Kernel.min(max) |> then(&(round(&1 / step) * step))
  end

  defp num(value, decimals) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: decimals)

  defp num(_, _), do: "—"

  defp phase_label(:decode_preview), do: "Loading preview"
  defp phase_label(:decode_full), do: "Loading file"
  defp phase_label(:master_preview), do: "Rendering preview"
  defp phase_label(:master_full), do: "Mastering"
  defp phase_label(:encode), do: "Encoding"
  defp phase_label(_), do: "Working"

  defp determinate?(phase), do: phase in [:master_preview, :master_full]

  defp working?(snap), do: snap.file != nil and snap.status in [:loading, :mastering]

  # the master is still being prepared, so Save must wait
  defp save_waiting?(snap), do: snap.file != nil and not save_ready?(snap)

  defp format_size(bytes) when bytes >= 1_000_000_000,
    do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"

  defp format_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_size(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} kB"
  defp format_size(bytes), do: "#{bytes} B"

  defp format_duration(nil), do: "—"

  defp format_duration(seconds) do
    total = round(seconds)
    minutes = div(total, 60)
    secs = rem(total, 60)
    "#{minutes}:#{String.pad_leading(to_string(secs), 2, "0")}"
  end
end
