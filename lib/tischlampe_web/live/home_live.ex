defmodule TischlampeWeb.HomeLive do
  @moduledoc """
  Quickmaster home screen: drop an audio file, tweak the Dyson compressor,
  listen to a preview and render a `_master` copy.
  """

  use TischlampeWeb, :live_view

  alias Tischlampe.Audio.FFmpeg
  alias Tischlampe.Session

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

    {:ok,
     socket
     |> assign(:snap, Session.snapshot())
     |> assign(:param_defs, param_defs())
     |> assign(:orig, nil)
     |> assign(:master, nil)
     |> assign(:playback, :stopped)
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

  def handle_event("preview", _params, socket) do
    Session.preview()
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

  def handle_info({:waveforms, orig, master}, socket) do
    socket = if orig, do: assign(socket, :orig, orig), else: socket
    socket = if master, do: assign(socket, :master, master), else: socket
    {:noreply, socket}
  end

  def handle_info({:playback, state}, socket), do: {:noreply, assign(socket, :playback, state)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="qm-app">
      <header class="qm-header">
        <div class="qm-brand">
          <span class="qm-logo">QM</span>
          <span class="qm-title">Quickmaster</span>
        </div>
        <div class="qm-subtitle">fast audio mastering · Dyson compressor</div>
      </header>

      <div :if={not @ffmpeg?} class="qm-alert">
        ffmpeg was not found on PATH. Install it (the project shell provides it) and restart.
      </div>

      <div :if={@snap.file == nil} class="qm-dropzone">
        <form id="qm-upload" phx-change="validate" phx-submit="validate">
          <label class="qm-drop">
            <div class="qm-drop-icon">♪</div>
            <div class="qm-drop-main">Drop an audio file here</div>
            <div class="qm-drop-sub">any format and size · click to browse</div>
            <.live_file_input upload={@uploads.audio} id="qm-input-drop" class="qm-file-input" />
          </label>
        </form>
        <div :if={@snap.status == :loading} class="qm-loading">Reading file…</div>
      </div>

      <div :if={@snap.file != nil} class="qm-main">
        <.file_panel snap={@snap} />

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
          <.wave label="Original" peaks={@orig} kind="orig" />
          <.wave label="Mastered" peaks={@master} kind="master" />
        </div>

        <div class="qm-panel qm-render">
          <div :if={@snap.status == :mastering} class="qm-progress">
            <div class="qm-progress-label">
              {phase_label(@snap.phase)}
              <span :if={@snap.phase == :master}>{round(@snap.percent)}%</span>
            </div>
            <div class="qm-bar" class={@snap.phase == :encode && "qm-bar-indeterminate"}>
              <div class="qm-bar-fill" style={"width: #{@snap.percent}%"}></div>
            </div>
          </div>

          <div :if={@snap.stale and @snap.status == :ready} class="qm-hint">
            Settings changed — the master is being recomputed.
          </div>

          <div class="qm-buttons">
            <button
              :if={@playback == :stopped}
              type="button"
              class="qm-btn qm-btn-primary"
              phx-click="preview"
              disabled={@snap.status == :loading}
            >
              ▶ Preview 30 s
            </button>
            <button
              :if={@playback == :playing}
              type="button"
              class="qm-btn qm-btn-stop"
              phx-click="stop_preview"
            >
              ■ Stop
            </button>
            <button
              type="button"
              class="qm-btn qm-btn-render"
              phx-click="render"
              disabled={@snap.status == :loading}
            >
              ⬇ Render master
            </button>
            <form id="qm-upload2" phx-change="validate" phx-submit="validate">
              <label class="qm-btn qm-btn-ghost">
                Load another file
                <.live_file_input upload={@uploads.audio} id="qm-input-more" class="qm-file-input" />
              </label>
            </form>
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

  defp file_panel(assigns) do
    ~H"""
    <div class="qm-panel qm-file">
      <div class="qm-file-name" title={@snap.file.name}>{@snap.file.name}</div>
      <div class="qm-file-meta">
        <span>{format_duration(@snap.file.duration)}</span>
        <span>{@snap.file.channels} ch</span>
        <span>{@snap.file.sample_rate} Hz</span>
        <span>{format_size(@snap.file.size)}</span>
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

  defp phase_label(:master), do: "Mastering"
  defp phase_label(:encode), do: "Encoding"
  defp phase_label(:decode), do: "Reading"
  defp phase_label(_), do: "Working"

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
