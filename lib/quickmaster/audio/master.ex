defmodule Quickmaster.Audio.Master do
  @moduledoc """
  Runs the Dyson compressor over a decoded raw f32le PCM file.

  Audio is interleaved; each channel gets its own `Dyson` instance. The file
  is streamed in frame-aligned chunks, so memory use is bounded and progress
  can be reported per chunk.

  Optional pregain stage normalizes to 0 dBFS peak before compression.
  """

  alias Quickmaster.Audio.{Dyson, Pregain}

  @frames_per_chunk 16_384

  @doc """
  Master `in_path` into `out_path` (both raw f32le).

  `progress` is called as `progress.(bytes_done, total_bytes)` after each chunk.

  If `params.pregain_enabled` is truthy, a pregain stage normalizes the
  input to 0 dBFS peak (clamped to `pregain_max_db`, default 20 dB) before
  the Dyson compressor.
  """
  @spec master_raw(Path.t(), Path.t(), pos_integer(), pos_integer(), map(), fun() | nil) :: :ok
  def master_raw(in_path, out_path, sample_rate, channels, params, progress \\ nil) do
    pregain_enabled = Map.get(params, :pregain_enabled, true)

    if pregain_enabled do
      master_raw_with_pregain(in_path, out_path, sample_rate, channels, params, progress)
    else
      master_raw_direct(in_path, out_path, sample_rate, channels, params, progress)
    end
  end

  defp master_raw_direct(in_path, out_path, sample_rate, channels, params, progress) do
    instances =
      List.duplicate(Dyson.new(sample_rate, params), channels) |> List.to_tuple()

    total = File.stat!(in_path).size
    {:ok, fin} = :file.open(in_path, [:read, :binary, :raw])
    {:ok, fout} = :file.open(out_path, [:write, :binary, :raw])

    try do
      loop(fin, fout, instances, channels, 0, total, progress)
    after
      :file.close(fin)
      :file.close(fout)
    end
  end

  defp master_raw_with_pregain(in_path, out_path, sample_rate, channels, params, progress) do
    max_db = Map.get(params, :pregain_max_db, 20.0)

    # Pass 1: scan for peaks
    peaks = scan_peaks(in_path, channels)
    gains = Pregain.compute_gains(peaks, max_db)

    # Pass 2: apply gains + Dyson
    instances =
      List.duplicate(Dyson.new(sample_rate, params), channels) |> List.to_tuple()

    total = File.stat!(in_path).size
    {:ok, fin} = :file.open(in_path, [:read, :binary, :raw])
    {:ok, fout} = :file.open(out_path, [:write, :binary, :raw])

    try do
      loop_with_gains(fin, fout, instances, channels, gains, 0, total, progress)
    after
      :file.close(fin)
      :file.close(fout)
    end
  end

  defp scan_peaks(path, channels) do
    {:ok, fd} = :file.open(path, [:read, :binary, :raw])
    total = File.stat!(path).size
    frame_bytes = channels * 4
    n = div(total, frame_bytes)
    try do
      scan_frames(fd, n, channels, List.duplicate(0.0, channels))
    after
      :file.close(fd)
    end
  end

  defp scan_frames(fd, n, channels, peaks) do
    if n == 0 do
      Enum.reverse(peaks)
    else
      {:ok, bin} = :file.read(fd, channels * 4 * min(n, 16_384))
      frame_bytes = channels * 4
      frame_count = div(byte_size(bin), frame_bytes)
      new_peaks = scan_binary(bin, frame_count, channels, peaks)
      scan_frames(fd, n - frame_count, channels, new_peaks)
    end
  end

  defp scan_binary(bin, n, channels, peaks, sample_idx \\ 0) do
    if n == 0 do
      peaks
    else
      {frame, rest} = :erlang.split_binary(bin, channels * 4)
      {frame_peaks, new_sample_idx} = frame_peaks(frame, channels, List.duplicate(0.0, channels), sample_idx)
      new_peaks = Enum.zip(peaks, frame_peaks) |> Enum.map(fn {a, b} -> max(a, b) end)
      scan_binary(rest, n - 1, channels, new_peaks, new_sample_idx)
    end
  end

  defp frame_peaks(<<>>, _channels, acc, _sample_idx), do: {Enum.reverse(acc), 0}

  defp frame_peaks(<<f::float-little-32, rest::binary>>, channels, acc, sample_idx) do
    idx = rem(sample_idx, channels)
    peak = max(abs(f), Enum.at(acc, idx))
    new_acc = List.replace_at(acc, idx, peak)
    {result, _} = frame_peaks(rest, channels, new_acc, sample_idx + 1)
    {result, 0}
  end

  defp loop_with_gains(fin, fout, instances, channels, gains, done, total, progress) do
    bytes = @frames_per_chunk * channels * 4

    case :file.read(fin, bytes) do
      :eof ->
        :ok

      {:ok, bin} ->
        {instances, out} = process_with_gains(instances, bin, channels, gains)
        :ok = :file.write(fout, out)
        done = done + byte_size(bin)
        if progress, do: progress.(done, total)
        loop_with_gains(fin, fout, instances, channels, gains, done, total, progress)
    end
  end

  defp process_with_gains({i0}, bin, 1, [g]) do
    {i0, out} =
      for <<x::float-little-32 <- bin>>, reduce: {i0, <<>>} do
        {s, acc} ->
          {y, s} = Dyson.step(s, x * g)
          {s, <<acc::binary, y::float-little-32>>}
      end

    {{i0}, out}
  end

  defp process_with_gains({i0, i1}, bin, 2, [gl, gr]) do
    {i0, i1, out} =
      for <<l::float-little-32, r::float-little-32 <- bin>>, reduce: {i0, i1, <<>>} do
        {s0, s1, acc} ->
          {yl, s0} = Dyson.step(s0, l * gl)
          {yr, s1} = Dyson.step(s1, r * gr)
          {s0, s1, <<acc::binary, yl::float-little-32, yr::float-little-32>>}
      end

    {{i0, i1}, out}
  end

  defp process_with_gains(instances, bin, channels, gains) do
    frame_bytes = channels * 4
    n = div(byte_size(bin), frame_bytes)
    generic_with_gains(bin, n, instances, channels, gains, <<>>)
  end

  defp generic_with_gains(_bin, 0, instances, _channels, _gains, acc), do: {instances, acc}

  defp generic_with_gains(bin, n, instances, channels, gains, acc) do
    {frame, rest} = :erlang.split_binary(bin, channels * 4)
    {instances, frame_out} = frame_with_gains(frame, instances, channels, gains, 0, [])
    generic_with_gains(rest, n - 1, instances, channels, gains, <<acc::binary, frame_out::binary>>)
  end

  defp frame_with_gains(<<>>, instances, _channels, _gains, _c, out), do: {instances, IO.iodata_to_binary(Enum.reverse(out))}

  defp frame_with_gains(<<x::float-little-32, rest::binary>>, instances, channels, gains, c, out) do
    gain = Enum.at(gains, c)
    {y, s} = Dyson.step(elem(instances, c), x * gain)
    frame_with_gains(rest, put_elem(instances, c, s), channels, gains, c + 1, [<<y::float-little-32>> | out])
  end

  @doc """
  Copy `frames` frames starting at `from_frame` from a raw f32le file into a
  32-bit float WAV file (used for preview playback).
  """
  @spec slice_to_wav(
          Path.t(),
          Path.t(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer()
        ) ::
          :ok
  def slice_to_wav(raw_path, wav_path, sample_rate, channels, from_frame, frames) do
    frame_bytes = channels * 4
    {:ok, fin} = :file.open(raw_path, [:read, :binary, :raw])

    data =
      try do
        case :file.pread(fin, from_frame * frame_bytes, frames * frame_bytes) do
          {:ok, bin} -> bin
          :eof -> <<>>
        end
      after
        :file.close(fin)
      end

    File.write!(wav_path, wav_header(sample_rate, channels, byte_size(data)) <> data)
  end

  ## internals (direct path, no pregain)

  defp loop(fin, fout, instances, channels, done, total, progress) do
    bytes = @frames_per_chunk * channels * 4

    case :file.read(fin, bytes) do
      :eof ->
        :ok

      {:ok, bin} ->
        {instances, out} = process(instances, bin, channels)
        :ok = :file.write(fout, out)
        done = done + byte_size(bin)
        if progress, do: progress.(done, total)
        loop(fin, fout, instances, channels, done, total, progress)
    end
  end

  defp process({i0}, bin, 1) do
    {i0, out} =
      for <<x::float-little-32 <- bin>>, reduce: {i0, <<>>} do
        {s, acc} ->
          {y, s} = Dyson.step(s, x)
          {s, <<acc::binary, y::float-little-32>>}
      end

    {{i0}, out}
  end

  defp process({i0, i1}, bin, 2) do
    {i0, i1, out} =
      for <<l::float-little-32, r::float-little-32 <- bin>>, reduce: {i0, i1, <<>>} do
        {s0, s1, acc} ->
          {yl, s0} = Dyson.step(s0, l)
          {yr, s1} = Dyson.step(s1, r)
          {s0, s1, <<acc::binary, yl::float-little-32, yr::float-little-32>>}
      end

    {{i0, i1}, out}
  end

  defp process(instances, bin, channels) do
    frame_bytes = channels * 4
    n = div(byte_size(bin), frame_bytes)
    generic(bin, n, instances, channels, <<>>)
  end

  defp generic(_bin, 0, instances, _channels, acc), do: {instances, acc}

  defp generic(bin, n, instances, channels, acc) do
    {frame, rest} = :erlang.split_binary(bin, channels * 4)
    {instances, frame_out} = frame(frame, instances, 0, [])
    generic(rest, n - 1, instances, channels, <<acc::binary, frame_out::binary>>)
  end

  defp frame(<<>>, instances, _c, out), do: {instances, IO.iodata_to_binary(Enum.reverse(out))}

  defp frame(<<x::float-little-32, rest::binary>>, instances, c, out) do
    {y, s} = Dyson.step(elem(instances, c), x)
    frame(rest, put_elem(instances, c, s), c + 1, [<<y::float-little-32>> | out])
  end

  defp wav_header(sample_rate, channels, data_bytes) do
    byte_rate = sample_rate * channels * 4

    <<
      "RIFF",
      byte_size(<<>>) + 36 + data_bytes::little-32,
      "WAVE",
      "fmt ",
      16::little-32,
      3::little-16,
      channels::little-16,
      sample_rate::little-32,
      byte_rate::little-32,
      channels * 4::little-16,
      32::little-16,
      "data",
      data_bytes::little-32
    >>
  end
end