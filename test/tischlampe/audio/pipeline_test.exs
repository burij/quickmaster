defmodule Tischlampe.Audio.PipelineTest do
  use ExUnit.Case, async: false

  alias Tischlampe.Audio.{FFmpeg, Master, Waveform}

  @moduletag :ffmpeg

  @params %{peak_limit: 0.0, release_time: 0.0, cfrate: 0.5, crate: 0.5}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "qm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "tone.wav")

    {_, 0} =
      System.cmd(
        Application.get_env(:tischlampe, :ffmpeg),
        [
          "-y",
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=3",
          "-ac",
          "2",
          "-ar",
          "44100",
          "-metadata",
          "title=T",
          "-metadata",
          "artist=A",
          input
        ],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, input: input}
  end

  test "decode, master and encode preserve format and metadata", %{dir: dir, input: input} do
    assert {:ok, info} = FFmpeg.probe(input)
    assert info.sample_rate == 44_100
    assert info.channels == 2

    raw = Path.join(dir, "raw.f32")
    assert {:ok, bytes} = FFmpeg.decode(input, raw)
    assert bytes == 3 * 44_100 * 2 * 4

    mraw = Path.join(dir, "master.f32")

    assert :ok =
             Master.master_raw(raw, mraw, info.sample_rate, info.channels, @params, fn _, _ -> :ok end)

    assert File.stat!(mraw).size == bytes

    out = Path.join(dir, "tone_master.wav")
    assert :ok = FFmpeg.encode(mraw, info.sample_rate, info.channels, input, out)
    assert {:ok, oinfo} = FFmpeg.probe(out)
    assert oinfo.codec_name == info.codec_name
    assert oinfo.channels == 2
    assert oinfo.bits_per_sample == info.bits_per_sample
    assert oinfo.tags["title"] == "T"
    assert oinfo.tags["artist"] == "A"
  end

  test "waveform returns min/max buckets per channel", %{dir: dir, input: input} do
    raw = Path.join(dir, "wf.f32")
    {:ok, _} = FFmpeg.decode(input, raw)

    peaks = Waveform.peaks(raw, 2, 32)
    assert length(peaks) == 2
    assert length(Enum.at(peaks, 0)) == 32

    for {lo, hi} <- Enum.at(peaks, 0), do: assert(lo <= hi)
  end

  test "slice_to_wav writes exactly the requested frames", %{dir: dir, input: input} do
    raw = Path.join(dir, "slice_src.f32")
    {:ok, _} = FFmpeg.decode(input, raw)

    preview = Path.join(dir, "preview.wav")
    assert :ok = Master.slice_to_wav(raw, preview, 44_100, 2, 44_100, 44_100)
    assert {:ok, pinfo} = FFmpeg.probe(preview)
    assert_in_delta pinfo.duration, 1.0, 0.001
  end

  test "master_raw reports progress up to the total", %{dir: dir, input: input} do
    raw = Path.join(dir, "prog.f32")
    {:ok, _} = FFmpeg.decode(input, raw)
    mraw = Path.join(dir, "prog_m.f32")

    {:ok, agent} = Agent.start_link(fn -> [] end)

    prog = fn done, total -> Agent.update(agent, &[{done, total} | &1]) end
    assert :ok = Master.master_raw(raw, mraw, 44_100, 2, @params, prog)

    {done, total} = Agent.get(agent, &hd/1)
    assert done == total
  end

  test "mono files decode and master", %{dir: dir} do
    mono = Path.join(dir, "mono.wav")

    {_, 0} =
      System.cmd(
        Application.get_env(:tischlampe, :ffmpeg),
        ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-ac", "1", mono],
        stderr_to_stdout: true
      )

    raw = Path.join(dir, "mono.f32")
    {:ok, _} = FFmpeg.decode(mono, raw)
    mraw = Path.join(dir, "mono_m.f32")
    assert :ok = Master.master_raw(raw, mraw, 44_100, 1, @params, nil)
    assert File.stat!(mraw).size == File.stat!(raw).size
  end
end