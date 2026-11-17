defmodule Quickmaster.Audio.Pregain do
  @moduledoc """
  Pregain stage: normalizes audio to 0 dBFS peak before the compressor.

  Scans the input for the absolute peak sample, computes a linear gain
  to bring that peak to 0 dBFS (1.0), clamped to a maximum gain
  (`max_db`, default 20 dB). This prevents very quiet files from
  mastering at low levels while avoiding excessive boost on already-loud
  material or noise floors.

  Applied per channel, before Dyson, in `Master.master_raw/6`.
  """

  @doc """
  Scan `bin` (interleaved f32le) and return the per-channel peak
  absolute value as a list of floats.
  """
  @spec scan_peaks(binary(), pos_integer()) :: [float()]
  def scan_peaks(bin, channels) do
    frame_bytes = channels * 4
    n = div(byte_size(bin), frame_bytes)
    scan(bin, n, channels, List.duplicate(0.0, channels), 0)
  end

  defp scan(_bin, 0, _channels, acc, _sample_idx), do: Enum.reverse(acc)

  defp scan(bin, n, channels, acc, sample_idx) do
    {frame, rest} = :erlang.split_binary(bin, channels * 4)
    {peaks, new_sample_idx} = frame_peaks(frame, channels, List.duplicate(0.0, channels), sample_idx)
    scan(rest, n - 1, channels, Enum.zip(acc, peaks) |> Enum.map(fn {a, b} -> max(a, b) end), new_sample_idx)
  end

  defp frame_peaks(<<>>, _channels, acc, sample_idx), do: {Enum.reverse(acc), sample_idx}

  defp frame_peaks(<<f::float-little-32, rest::binary>>, channels, acc, sample_idx) do
    idx = rem(sample_idx, channels)
    peak = max(abs(f), Enum.at(acc, idx))
    new_acc = List.replace_at(acc, idx, peak)
    frame_peaks(rest, channels, new_acc, sample_idx + 1)
  end

  @doc """
  Compute per-channel gain to normalize peaks to 0 dBFS,
  clamped to `max_db` (linear gain = 10^(max_db/20)).
  """
  @spec compute_gains([float()], number()) :: [float()]
  def compute_gains(peaks, max_db) do
    max_gain = :math.pow(10.0, max_db / 20.0)
    Enum.map(peaks, fn
      +0.0 -> 1.0
      peak -> min(1.0 / peak, max_gain)
    end)
  end

  @doc """
  Apply per-channel gains to interleaved f32le binary.
  """
  @spec apply(binary(), [float()], pos_integer()) :: binary()
  def apply(bin, gains, channels) do
    frame_bytes = channels * 4
    n = div(byte_size(bin), frame_bytes)
    apply_frames(bin, n, channels, gains, 0, <<>>)
  end

  defp apply_frames(_bin, 0, _channels, _gains, _sample_idx, acc), do: acc

  defp apply_frames(bin, n, channels, gains, sample_idx, acc) do
    {frame, rest} = :erlang.split_binary(bin, channels * 4)
    {frame_out, new_sample_idx} = apply_frame(frame, channels, gains, sample_idx)
    apply_frames(rest, n - 1, channels, gains, new_sample_idx, <<acc::binary, frame_out::binary>>)
  end

  defp apply_frame(<<>>, _channels, _gains, sample_idx), do: {<<>>, sample_idx}

  defp apply_frame(<<f::float-little-32, rest::binary>>, channels, gains, sample_idx) do
    idx = rem(sample_idx, channels)
    gain = Enum.at(gains, idx)
    {out_rest, new_sample_idx} = apply_frame(rest, channels, gains, sample_idx + 1)
    {<<(f * gain)::float-little-32, out_rest::binary>>, new_sample_idx}
  end
end