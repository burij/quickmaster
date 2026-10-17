defmodule Quickmaster.Session do
  @moduledoc """
  Owns the mastering workflow for the desktop app.

  Holds the dropped file, its decoded raw PCM, the mastered raw PCM and the
  waveforms; runs decode/master/encode in supervised tasks and broadcasts
  progress and results on a PubSub topic.

  Mastering is recomputed in the background whenever parameters change, so
  preview and render only need to read the cached mastered PCM. A single
  `advance/1` step decides what to do next, which keeps the concurrent cases
  (parameter change during mastering, preview while mastering, ...) simple.
  """

  use GenServer

  alias Quickmaster.Audio.{FFmpeg, Master, Player, Waveform}

  @topic "qm:session"
  @debounce_ms 400
  @buckets 900
  @preview_buckets 320
  @preview_ratio 0.30
  @preview_seconds 30

  # release_time defaults to 0.25 s: the plugin's nominal 0.0 makes the
  # release filter extrapolate and is not usable for mastering.
  @default_params %{peak_limit: 0.0, release_time: 0.25, cfrate: 0.5, crate: 0.5}

  ## public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribe the calling process to session broadcasts."
  def subscribe, do: Phoenix.PubSub.subscribe(Quickmaster.PubSub, @topic)

  @doc "Current public snapshot (everything except the waveforms)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Drop the current file and go back to the empty state."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Load `path` (uploaded temp file) under its original `name`."
  def load(path, name), do: GenServer.call(__MODULE__, {:load, path, name}, 120_000)

  @doc "Load a file from a native path, without copying it."
  def load_file(path), do: GenServer.call(__MODULE__, {:load_file, path}, 120_000)

  def set_params(params), do: GenServer.cast(__MODULE__, {:set_params, params})

  @doc "Render to a path chosen in the native save dialog."
  def render, do: GenServer.cast(__MODULE__, {:render, :ask})

  @doc "Render to an explicit path, skipping the dialog (menu and tests)."
  def render_to(path), do: GenServer.cast(__MODULE__, {:render, path})

  @doc "Play the 30 s preview of `:original` or `:master`."
  def preview(source \\ :master), do: GenServer.cast(__MODULE__, {:preview, source})

  def stop_preview, do: GenServer.cast(__MODULE__, :stop_preview)

  @doc "Current waveforms (full and preview region) for a fresh LiveView."
  def waveforms, do: GenServer.call(__MODULE__, :waveforms)

  def default_params, do: @default_params

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, blank(%{params: @default_params})}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call(:reset, _from, state) do
    _ = state |> stop_task() |> stop_player()
    state = blank(%{params: @default_params})
    broadcast_session(state)
    broadcast({:waveforms, waves(state)})
    {:reply, :ok, state}
  end

  def handle_call(:waveforms, _from, state), do: {:reply, waves(state), state}

  def handle_call({:load, path, name}, _from, state) do
    dir = work_dir()
    File.mkdir_p!(dir)
    dest = Path.join(dir, "original" <> Path.extname(name))
    File.cp!(path, dest)
    {:reply, :ok, start_input(state, dest, name, :upload)}
  end

  def handle_call({:load_file, path}, _from, state) do
    if File.regular?(path) do
      {:reply, :ok, start_input(state, path, Path.basename(path), :native)}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast({:set_params, params}, state) do
    state = stop_player(%{state | params: params, error: nil})

    # A run with the old parameters is pointless once they changed.
    state = if match?(%{kind: :master}, state.task), do: stop_task(state), else: state

    broadcast_session(state)
    {:noreply, schedule_advance(state)}
  end

  def handle_cast({:render, path}, state) do
    if state.raw,
      do: {:noreply, schedule_advance(%{state | pending: {:render, path}})},
      else: {:noreply, state}
  end

  def handle_cast({:preview, source}, state) do
    if state.raw,
      do: {:noreply, schedule_advance(%{state | pending: {:preview, source}})},
      else: {:noreply, state}
  end

  def handle_cast(:stop_preview, state), do: {:noreply, stop_player(state)}

  @impl true
  def handle_info(:advance, state) do
    {:noreply, advance(%{state | timer: nil})}
  end

  def handle_info({:task_progress, ref, phase, done, total}, %{task: %{ref: ref}} = state) do
    percent = if total > 0, do: done / total * 100.0, else: 0.0
    broadcast({:progress, phase, percent})
    {:noreply, %{state | percent: percent, phase: phase}}
  end

  def handle_info({:task_done, ref, kind, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(state.task.mon, [:flush])
    {:noreply, advance(finish(kind, result, %{state | task: nil, percent: 0.0, phase: nil}))}
  end

  def handle_info({:task_error, ref, _kind, message}, %{task: %{ref: ref}} = state) do
    Process.demonitor(state.task.mon, [:flush])
    {:noreply, fail(%{state | task: nil}, message)}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{task: %{mon: mon}} = state) do
    {:noreply, %{state | task: nil}}
  end

  def handle_info({port, {:exit_status, _status}}, %{player: port} = state) do
    broadcast({:playback, nil})
    {:noreply, %{state | player: nil}}
  end

  def handle_info({_port, {:exit_status, _}}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## the single decision step

  defp advance(%{task: nil} = state) do
    cond do
      state.raw == nil ->
        state

      # the original preview does not need a fresh master
      match?({:preview, :original}, state.pending) ->
        {:preview, source} = state.pending
        run_preview(%{state | pending: nil}, source)

      not mastered_current?(state) ->
        start_task(state, :master)

      match?({:preview, _}, state.pending) ->
        {:preview, source} = state.pending
        run_preview(%{state | pending: nil}, source)

      match?({:render, _}, state.pending) ->
        {:render, path} = state.pending
        run_render(%{state | pending: nil}, path)

      true ->
        state
    end
  end

  defp advance(state), do: state

  defp mastered_current?(state) do
    is_binary(state.mastered) and state.mastered_params == state.params
  end

  ## task results

  defp finish(:decode, {:ok, info, raw, waveform, preview}, state) do
    state = %{
      state
      | status: :ready,
        info: info,
        raw: raw,
        orig_waveform: waveform,
        orig_preview: preview,
        master_waveform: nil,
        master_preview: nil,
        error: nil
    }

    broadcast_session(state)
    broadcast({:waveforms, waves(state)})
    state
  end

  defp finish(:decode, {:error, reason}, state),
    do: fail(state, "Could not decode this file: #{reason_text(reason)}")

  defp finish(:master, {:ok, mastered, waveform, preview, params}, state) do
    state = %{
      state
      | status: :ready,
        mastered: mastered,
        mastered_params: params,
        master_waveform: waveform,
        master_preview: preview,
        error: nil
    }

    broadcast_session(state)
    broadcast({:waveforms, waves(state)})
    state
  end

  defp finish(:master, {:error, reason}, state),
    do: fail(state, "Mastering failed: #{reason_text(reason)}")

  defp finish(:render, {:ok, output}, state) do
    state = %{state | status: :ready, output: output, error: nil}
    broadcast_session(state)
    state
  end

  defp finish(:render, {:error, reason}, state),
    do: fail(state, "Render failed: #{reason_text(reason)}")

  defp finish(_kind, _result, state), do: state

  ## workflow steps

  defp run_preview(state, source) do
    info = state.info
    raw = if source == :original, do: state.raw, else: state.mastered
    total_frames = div(File.stat!(raw).size, 4 * info.channels)
    {from, frames} = preview_window(total_frames, info.sample_rate)
    wav = Path.join(state.work_dir, "preview_#{source}.wav")

    Master.slice_to_wav(raw, wav, info.sample_rate, info.channels, from, frames)
    state = stop_player(state)

    case Player.play(wav) do
      {:ok, port} ->
        broadcast({:playback, source})
        %{state | player: port}

      {:error, reason} ->
        fail(state, "Playback failed: #{reason_text(reason)}")
    end
  end

  defp preview_window(total_frames, sample_rate) do
    window = trunc(@preview_seconds * sample_rate)

    if total_frames <= window do
      {0, total_frames}
    else
      from = min(trunc(total_frames * @preview_ratio), total_frames - window)
      {from, window}
    end
  end

  ## tasks

  defp start_task(%{task: nil} = state, :decode) do
    input = state.input

    run_task(state, :decode, fn _progress ->
      with {:ok, info} <- FFmpeg.probe(input.path) do
        raw = Path.join(state.work_dir, "decoded.f32")
        {:ok, _} = FFmpeg.decode(input.path, raw)
        total = div(File.stat!(raw).size, 4 * info.channels)
        window = preview_window(total, info.sample_rate)

        {:ok, info, raw, Waveform.peaks(raw, info.channels, @buckets),
         Waveform.peaks(raw, info.channels, @preview_buckets, window)}
      end
    end)
  end

  defp start_task(%{task: nil} = state, :master) do
    state = %{state | status: :mastering, phase: :master, percent: 0.0}
    broadcast_session(state)

    info = state.info
    params = state.params
    decoded = state.raw

    run_task(state, :master, fn progress ->
      mastered = Path.join(state.work_dir, "mastered.f32")

      Master.master_raw(decoded, mastered, info.sample_rate, info.channels, params, fn d, t ->
        progress.(:master, d, t)
      end)

      total = div(File.stat!(mastered).size, 4 * info.channels)
      window = preview_window(total, info.sample_rate)

      {:ok, mastered, Waveform.peaks(mastered, info.channels, @buckets),
       Waveform.peaks(mastered, info.channels, @preview_buckets, window), params}
    end)
  end

  defp start_task(state, _kind), do: state

  # `:ask` opens the native save dialog; an explicit path skips it.
  defp run_render(state, :ask) do
    case Quickmaster.FileDialog.save(default_output_path(state)) do
      nil -> state
      path -> start_render(state, path)
    end
  end

  defp run_render(state, path), do: start_render(state, path)

  defp start_render(state, out) do
    File.mkdir_p!(Path.dirname(out))
    state = %{state | status: :mastering, phase: :encode, percent: 0.0}
    broadcast_session(state)

    info = state.info
    input = state.input
    mastered = state.mastered

    run_task(state, :render, fn _progress ->
      FFmpeg.encode(mastered, info.sample_rate, info.channels, input.path, out)
      {:ok, out}
    end)
  end

  defp run_task(state, kind, fun) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        progress = fn phase, done, total ->
          send(parent, {:task_progress, ref, phase, done, total})
        end

        try do
          send(parent, {:task_done, ref, kind, fun.(progress)})
        rescue
          e ->
            send(parent, {:task_error, ref, kind, Exception.format(:error, e, __STACKTRACE__)})
        end
      end)

    %{state | task: %{ref: ref, pid: pid, mon: mon, kind: kind}}
  end

  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(%{task: %{pid: pid, mon: mon}} = state) do
    Process.demonitor(mon, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    %{state | task: nil, percent: 0.0, phase: nil}
  end

  defp schedule_advance(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :advance, @debounce_ms)}
  end

  ## player

  defp stop_player(%{player: nil} = state), do: state

  defp stop_player(%{player: port} = state) do
    Player.stop(port)
    broadcast({:playback, nil})
    %{state | player: nil}
  end

  ## helpers

  # A newly selected file starts from the plugin defaults again.
  defp start_input(state, path, name, origin) do
    _ = state |> stop_task() |> stop_player()

    dir = work_dir()
    File.mkdir_p!(dir)

    state =
      blank(%{params: @default_params})
      |> Map.merge(%{
        status: :loading,
        work_dir: dir,
        input: %{path: path, name: name, size: File.stat!(path).size, origin: origin}
      })

    broadcast_session(state)
    start_task(state, :decode)
  end

  defp blank(state) do
    %{
      status: :empty,
      params: state.params || @default_params,
      work_dir: nil,
      input: nil,
      info: nil,
      raw: nil,
      mastered: nil,
      mastered_params: nil,
      orig_waveform: nil,
      master_waveform: nil,
      orig_preview: nil,
      master_preview: nil,
      percent: 0.0,
      phase: nil,
      error: nil,
      output: nil,
      player: nil,
      task: nil,
      timer: nil,
      pending: nil
    }
  end

  defp fail(state, message) do
    state = %{state | status: :error, error: message, phase: nil, percent: 0.0}
    broadcast_session(state)
    state
  end

  defp waves(state) do
    %{
      original: state.orig_waveform,
      mastered: state.master_waveform,
      original_preview: state.orig_preview,
      mastered_preview: state.master_preview
    }
  end

  defp broadcast_session(state), do: broadcast({:session, public(state)})

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Quickmaster.PubSub, @topic, msg)

  defp public(state) do
    %{
      status: state.status,
      params: state.params,
      file: file_public(state),
      percent: state.percent || 0.0,
      phase: state.phase,
      stale: not mastered_current?(state),
      error: state.error,
      output: state.output,
      output_dir: output_dir()
    }
  end

  defp file_public(%{input: nil}), do: nil

  defp file_public(state) do
    %{
      name: state.input.name,
      size: state.input.size,
      duration: state.info && state.info.duration,
      sample_rate: state.info && state.info.sample_rate,
      channels: state.info && state.info.channels
    }
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp work_dir,
    do: Path.join(System.tmp_dir!(), "quickmaster/#{System.unique_integer([:positive])}")

  # Suggested save path: next to the opened file, or in the output dir for
  # uploads (where the original directory is unknown).
  defp default_output_path(state) do
    name = state.input.name

    dir =
      case state.input do
        %{origin: :native, path: path} -> Path.dirname(path)
        _ -> output_dir()
      end

    Path.join(dir, Path.rootname(name) <> "_master" <> Path.extname(name))
  end

  defp output_dir do
    Application.get_env(:quickmaster, :output_dir) || default_output_dir()
  end

  defp default_output_dir do
    home = System.user_home() || System.tmp_dir!()

    Enum.find(
      [Path.join(home, "Music"), Path.join(home, "Downloads"), home],
      System.tmp_dir!(),
      &File.dir?/1
    )
  end
end
