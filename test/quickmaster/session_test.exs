defmodule Quickmaster.SessionTest do
  use ExUnit.Case, async: false

  alias Quickmaster.Audio.FFmpeg
  alias Quickmaster.Session

  @moduletag :ffmpeg

  setup do
    dir = Path.join(System.tmp_dir!(), "qm_sess_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "tone.wav")

    {_, 0} =
      System.cmd(
        Application.get_env(:quickmaster, :ffmpeg),
        [
          "-y",
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=1",
          "-ac",
          "2",
          "-ar",
          "44100",
          "-metadata",
          "title=T",
          input
        ],
        stderr_to_stdout: true
      )

    Application.put_env(:quickmaster, :output_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, input: input}
  end

  test "loads a file, masters it and renders a master copy", %{dir: dir, input: input} do
    assert :ok = Session.load(input, "tone.wav")
    wait_until(fn -> Session.snapshot().status == :ready end)
    wait_until(fn -> not Session.snapshot().stale end)

    snap = Session.snapshot()
    assert snap.file.name == "tone.wav"
    assert snap.file.channels == 2
    assert snap.file.sample_rate == 44_100
    assert snap.params == Session.default_params()

    Session.render_to(Path.join(dir, "tone_master.wav"))
    wait_until(fn -> Session.snapshot().output != nil end, 30_000)

    [output] = Path.wildcard(Path.join(dir, "tone_master.wav"))
    assert {:ok, info} = FFmpeg.probe(output)
    assert info.channels == 2
    assert info.bits_per_sample == 16
    assert info.tags["title"] == "T"
  end

  test "load_file uses a native path without copying", %{input: input} do
    assert :ok = Session.load_file(input)
    wait_until(fn -> Session.snapshot().status == :ready end)

    snap = Session.snapshot()
    assert snap.file.name == "tone.wav"
    assert snap.file.size == File.stat!(input).size
    wait_until(fn -> not Session.snapshot().stale end)
  end

  test "prepares the preview region before the whole file", %{input: input} do
    Session.subscribe()
    assert :ok = Session.load_file(input)

    phases = collect_phases([])
    assert_before(phases, :decode_preview, :decode_full)
    assert_before(phases, :master_preview, :master_full)
    assert_before(phases, :decode_preview, :master_preview)
  end

  test "waveforms expose the preview region for both original and master", %{input: input} do
    assert :ok = Session.load_file(input)
    wait_until(fn -> Session.snapshot().status == :ready end)
    wait_until(fn -> not Session.snapshot().stale end)

    waves = Session.waveforms()
    assert length(waves.original_preview) == 2
    assert waves.original_preview |> hd() |> length() > 0
    assert length(waves.mastered_preview) == 2
    assert waves.mastered_preview |> hd() |> length() > 0
    assert waves.original_preview != waves.mastered_preview
  end

  test "load_file rejects a missing path" do
    assert {:error, :not_found} = Session.load_file("/does/not/exist.wav")
  end

  test "changing parameters marks the master stale and recomputes it", %{input: input} do
    assert :ok = Session.load(input, "stale.wav")
    wait_until(fn -> Session.snapshot().status == :ready end)
    wait_until(fn -> not Session.snapshot().stale end)

    params = %{peak_limit: -6.0, release_time: 0.3, cfrate: 0.4, crate: 0.6}
    Session.set_params(params)

    wait_until(fn -> Session.snapshot().params == params and not Session.snapshot().stale end)
    assert Session.snapshot().params == params
  end

  # Collect the broadcast phases until the pipeline is finished.
  defp collect_phases(acc) do
    if Session.snapshot().status == :ready and not Session.snapshot().stale do
      acc
    else
      receive do
        {:session, %{phase: phase}} when is_atom(phase) and not is_nil(phase) ->
          collect_phases([phase | acc])

        {:progress, phase, _percent} ->
          collect_phases([phase | acc])

        _other ->
          collect_phases(acc)
      after
        30_000 -> flunk("timed out collecting phases, got #{inspect(Enum.reverse(acc))}")
      end
    end
  end

  defp assert_before(phases, first, second) do
    ordered = Enum.reverse(phases)
    i = Enum.find_index(ordered, &(&1 == first))
    j = Enum.find_index(ordered, &(&1 == second))
    assert i != nil, "phase #{first} was never seen in #{inspect(ordered)}"
    assert j != nil, "phase #{second} was never seen in #{inspect(ordered)}"
    assert i < j, "expected #{first} before #{second} in #{inspect(ordered)}"
  end

  defp wait_until(fun, timeout \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("timed out waiting")
      Process.sleep(30)
      do_wait(fun, deadline)
    end
  end
end
