defmodule Quickmaster.Audio.Waveform do
  @moduledoc """
  Peak envelopes for drawing waveforms.

  Reads a raw f32le PCM file in bucket-sized windows (so memory stays
  bounded for arbitrarily large files) and uses Nx to reduce each window
  to `{min, max}` per channel.
  """

  @doc """
  Return `[[{min, max}, ...], ...]`, one list of `buckets` values per channel.
  """
  @spec peaks(Path.t(), pos_integer(), pos_integer()) :: [[{float(), float()}]]
  def peaks(path, channels, buckets) do
    size = File.stat!(path).size
    frames = div(size, 4 * channels)
    bucket_frames = max(1, div(frames + buckets - 1, buckets))

    {:ok, fd} = :file.open(path, [:read, :binary, :raw])

    try do
      for ch <- 0..(channels - 1) do
        for b <- 0..(buckets - 1) do
          bucket(fd, b, bucket_frames, frames, channels, ch)
        end
      end
    after
      :file.close(fd)
    end
  end

  defp bucket(fd, b, bucket_frames, frames, channels, ch) do
    first = b * bucket_frames
    n = min(bucket_frames, frames - first)

    if n <= 0 do
      {0.0, 0.0}
    else
      bytes = n * channels * 4
      offset = first * channels * 4
      {:ok, bin} = :file.pread(fd, offset, bytes)

      t =
        Nx.from_binary(bin, :f32)
        |> Nx.reshape({n, channels})
        |> Nx.slice_along_axis(ch, 1, axis: 1)

      {Nx.to_number(Nx.reduce_min(t)), Nx.to_number(Nx.reduce_max(t))}
    end
  end
end
