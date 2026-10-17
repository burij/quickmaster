defmodule Quickmaster.Audio.Waveform do
  @moduledoc """
  Peak envelopes for drawing waveforms.

  One bucket-sized read and one binary pass per channel. Deliberately not
  Nx: Nx's pure-Elixir backend costs ~8 µs per element, roughly 50x slower
  than this direct loop, which made long files feel stuck.
  """

  @big 1.0e38

  @doc """
  Return `[[{min, max}, ...], ...]`, one list of `buckets` values per channel.

  `range` optionally limits the analysed part to `{from_frame, frames}`.
  """
  @spec peaks(Path.t(), pos_integer(), pos_integer(), {non_neg_integer(), pos_integer()} | nil) ::
          [[{float(), float()}]]
  def peaks(path, channels, buckets, range \\ nil) do
    size = File.stat!(path).size
    total = div(size, 4 * channels)
    {from, wanted} = range || {0, total}
    frames = max(0, min(wanted, total - from))
    bucket_frames = max(1, div(frames + buckets - 1, buckets))

    {:ok, fd} = :file.open(path, [:read, :binary, :raw])

    try do
      for ch <- 0..(channels - 1) do
        channel(fd, from, frames, bucket_frames, channels, ch, buckets)
      end
    after
      :file.close(fd)
    end
  end

  defp channel(fd, from, frames, bf, channels, ch, buckets) do
    # bytes to skip at the start of every frame to land on this channel
    skip = ch * 4
    collect(fd, from, frames, bf, channels, skip, 0, buckets, [])
  end

  defp collect(_fd, _from, _frames, _bf, _channels, _skip, b, buckets, acc)
       when b >= buckets do
    Enum.reverse(acc)
  end

  defp collect(fd, from, frames, bf, channels, skip, b, buckets, acc) do
    n = min(bf, frames - b * bf)

    pair =
      if n <= 0 do
        {0.0, 0.0}
      else
        offset = (from + b * bf) * channels * 4
        {:ok, bin} = :file.pread(fd, offset, n * channels * 4)
        scan(bin, skip, @big, -@big)
      end

    collect(fd, from, frames, bf, channels, skip, b + 1, buckets, [pair | acc])
  end

  # A `case` (not a head pattern) so `skip` is already bound for binary-size.
  # `if` instead of `min/2`/`max/2`: the BIFs are noticeably slower here.
  defp scan(bin, skip, lo, hi) do
    case bin do
      <<_::binary-size(skip), x::float-little-32, rest::binary>> ->
        lo = if x < lo, do: x, else: lo
        hi = if x > hi, do: x, else: hi
        scan(rest, skip, lo, hi)

      _ ->
        {lo, hi}
    end
  end
end
