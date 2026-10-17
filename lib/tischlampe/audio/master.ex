defmodule Tischlampe.Audio.Master do
  @moduledoc """
  Runs the Dyson compressor over a decoded raw f32le PCM file.

  Audio is interleaved; each channel gets its own `Dyson` instance. The file
  is streamed in frame-aligned chunks, so memory use is bounded and progress
  can be reported per chunk.
  """

  alias Tischlampe.Audio.Dyson

  @frames_per_chunk 16_384

  @doc """
  Master `in_path` into `out_path` (both raw f32le).

  `progress` is called as `progress.(bytes_done, total_bytes)` after each chunk.
  """
  @spec master_raw(Path.t(), Path.t(), pos_integer(), pos_integer(), map(), fun() | nil) :: :ok
  def master_raw(in_path, out_path, sample_rate, channels, params, progress \\ nil) do
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

  @doc """
  Copy `frames` frames starting at `from_frame` from a raw f32le file into a
  32-bit float WAV file (used for preview playback).
  """
  @spec slice_to_wav(Path.t(), Path.t(), pos_integer(), pos_integer(), non_neg_integer(), pos_integer()) ::
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

  ## internals

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