defmodule Tischlampe.Session do
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

  alias Tischlampe.Audio.{FFmpeg, Master, Player, Waveform}

  @topic "qm:session"
  @debounce_ms 400
  @buckets 900
  @preview_ratio 0.30
  @preview_seconds 30

  @default_params %{peak_limit: 0.0, release_time: 0.0, cfrate: 0.5, crate: 0.5}

  ## public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribe the calling process to session broadcasts."
  def subscribe, do: Phoenix.PubSub.subscribe(Tischlampe.PubSub, @topic)

  @doc "Current public snapshot (everything except the waveforms)."
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Load `path` (uploaded temp file) under its original `name`."
  def load(path, name), do: GenServer.call(__MODULE__, {:load, path, name}, 30_000)

  def set_params(params), do: GenServer.cast(__MODULE__, {:set_params, params})

  def render, do: GenServer.cast(__MODULE__, :render)

  def preview, do: GenServer.cast(__MODULE__, :preview)

  def stop_preview, do: GenServer.cast(__MODULE__, :stop_preview)

  def default_params, do: @default_params

  ## GenServer

  @impl true
  def init(_opts), do: {:ok, blank(%{params: @default_params})}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call({:load, path, name}, _from, state) do
    stop_task(state)
    stop_player(state)

    dir = work_dir()
    File.mkdir_p!(dir)
    dest = Path.join(dir, "original" <> Path.extname(name))
    File.cp!(path, dest)

    # A newly dropped file starts from the plugin defaults again.
    state =
      blank(%{params: @default_params})
      |> Map.merge(%{
        status: :loading,
        work_dir: dir,
        input: %{path: dest, name: name, size: File.stat!(dest).size}
      })

    broadcast_session(state)
    {:reply, :ok, start_task(state, :decode)}
  end

  @impl true
  def handle_cast({:set_params, params}, state) do
    state = %{state | params: params, error: nil}

    # A run with the old parameters is pointless once they changed.
    state = if match?(%{kind: :master}, state.task), do: stop_task(state), else: state

    broadcast_session(state)
    {:noreply, schedule_advance(state)}
  end

  def handle_cast(:render, state) do
    if state.raw, do: {:noreply, schedule_advance(%{state | pending: :render})}, else: {:noreply, state}
  end

  def handle_cast(:preview, state) do
    if state.raw,
      do: {:noreply, schedule_advance(%{state | pending: :preview})},
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
    broadcast({:playback, :stopped})
    {:noreply, %{state | player: nil}}
  end

  def handle_info({_port, {:exit_status, _}}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## the single decision step

  defp advance(%{task: nil} = state) do
    cond do
      state.raw == nil ->
        state

      not mastered_current?(state) ->
        start_task(state, :master)

      state.pending == :preview ->
        run_preview(%{state | pending: nil})

      state.pending == :render ->
        start_task(%{state | pending: nil}, :render)

      true ->
        state
    end
  end

  defp advance(state), do: state

  defp mastered_current?(state) do
    is_binary(state.mastered) and state.mastered_params == state.params
  end

  ## task results

  defp finish(:decode, {:ok, info, raw, waveform}, state) do
    state = %{
      state
      | status: :ready,
        info: info,
        raw: raw,
        orig_waveform: waveform,
        error: nil
    }

    broadcast_session(state)
    broadcast({:waveforms, waveform, nil})
    state
  end

  defp finish(:decode, {:error, reason}, state),
    do: fail(state, "Could not decode this file: #{reason_text(reason)}")

  defp finish(:master, {:ok, mastered, waveform, params}, state) do
    state = %{
      state
      | status: :ready,
        mastered: mastered,
        mastered_params: params,
        master_waveform: waveform,
        error: nil
    }

    broadcast_session(state)
    broadcast({:waveforms, state.orig_waveform, waveform})
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

  defp run_preview(state) do
    info = state.info
    total_frames = div(File.stat!(state.mastered).size, 4 * info.channels)
    {from, frames} = preview_window(total_frames, info.sample_rate)
    wav = Path.join(state.work_dir, "preview.wav")

    Master.slice_to_wav(state.mastered, wav, info.sample_rate, info.channels, from, frames)
    state = stop_player(state)

    case Player.play(wav) do
      {:ok, port} ->
        broadcast({:playback, :playing})
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
        {:ok, info, raw, Waveform.peaks(raw, info.channels, @buckets)}
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

      {:ok, mastered, Waveform.peaks(mastered, info.channels, @buckets), params}
    end)
  end

  defp start_task(%{task: nil} = state, :render) do
    state = %{state | status: :mastering, phase: :encode, percent: 0.0}
    broadcast_session(state)

    info = state.info
    input = state.input
    mastered = state.mastered
    name = input.name
    out = Path.join(output_dir(), Path.rootname(name) <> "_master" <> Path.extname(name))
    File.mkdir_p!(output_dir())

    run_task(state, :render, fn _progress ->
      FFmpeg.encode(mastered, info.sample_rate, info.channels, input.path, out)
      {:ok, out}
    end)
  end

  defp start_task(state, _kind), do: state

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
    %{state | player: nil}
  end

  ## helpers

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

  defp broadcast_session(state), do: broadcast({:session, public(state)})

  defp broadcast(msg), do: Phoenix.PubSub.broadcast(Tischlampe.PubSub, @topic, msg)

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

  defp output_dir do
    Application.get_env(:tischlampe, :output_dir) || default_output_dir()
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