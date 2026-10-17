defmodule Tischlampe.Audio.FFmpeg do
  @moduledoc """
  Decode and encode audio with the `ffmpeg`/`ffprobe` executables.

  Decoding always produces raw little-endian float32 PCM, one channel after
  another (planar by convention: channel data is split by the caller).
  Encoding writes the original file's format and metadata back, so the
  master keeps everything except the audio samples.

  The executable names can be overridden with
  `config :tischlampe, ffmpeg: "/path/to/ffmpeg"` (and `:ffprobe`).
  """

  @type info :: %{
          duration: float() | nil,
          sample_rate: pos_integer(),
          channels: pos_integer(),
          codec_name: String.t(),
          format_name: String.t() | nil,
          bits_per_raw_sample: integer() | nil,
          bits_per_sample: integer() | nil,
          sample_fmt: String.t() | nil,
          tags: map()
        }

  @doc "Return audio format information for `path`."
  @spec probe(Path.t()) :: {:ok, info()} | {:error, term()}
  def probe(path) do
    args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", path]

    with {:ok, out} <- run(ffprobe(), args),
         {:ok, json} <- Jason.decode(out) do
      parse_probe(json)
    end
  end

  @doc """
  Decode `path` to raw f32le PCM at `out`.

  Options: `:start` (seconds) and `:duration` (seconds) to decode a slice,
  otherwise the whole file.
  """
  @spec decode(Path.t(), Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode(path, out, opts \\ []) do
    slice =
      []
      |> add_opt("-ss", opts[:start])
      |> add_opt("-t", opts[:duration])

    args =
      ["-y", "-v", "error", "-i", path, "-map", "0:a:0"] ++
        slice ++ ["-f", "f32le", "-acodec", "pcm_f32le", out]

    with {:ok, _} <- run(ffmpeg(), args),
         %File.Stat{size: size} <- File.stat!(out) do
      {:ok, size}
    end
  end

  @doc """
  Encode raw f32le PCM (`raw`, with `sample_rate`/`channels`) to `out`,
  taking format and metadata from `original`.
  """
  @spec encode(Path.t(), pos_integer(), pos_integer(), Path.t(), Path.t()) ::
          :ok | {:error, term()}
  def encode(raw, sample_rate, channels, original, out) do
    codec = output_codec(out, original)

    args =
      [
        "-y",
        "-v",
        "error",
        "-f",
        "f32le",
        "-ar",
        to_string(sample_rate),
        "-ac",
        to_string(channels),
        "-i",
        raw,
        "-i",
        original,
        "-map",
        "0:a",
        "-map_metadata",
        "1"
      ] ++ codec ++ [out]

    with {:ok, _} <- run(ffmpeg(), args), do: :ok
  end

  @doc "True when the ffmpeg executable can be found."
  @spec available?() :: boolean()
  def available? do
    not is_nil(System.find_executable(ffmpeg())) and
      not is_nil(System.find_executable(ffprobe()))
  end

  ## internals

  defp parse_probe(%{"streams" => streams} = json) do
    case Enum.find(streams, &(&1["codec_type"] == "audio")) do
      nil ->
        {:error, :no_audio_stream}

      s ->
        fmt = json["format"] || %{}

        {:ok,
         %{
           duration: to_float(fmt["duration"]),
           sample_rate: to_int(s["sample_rate"]),
           channels: to_int(s["channels"]) || 1,
           codec_name: s["codec_name"],
           format_name: fmt["format_name"],
           bits_per_raw_sample: to_int(s["bits_per_raw_sample"]),
           bits_per_sample: to_int(s["bits_per_sample"]),
           sample_fmt: s["sample_fmt"],
           tags: Map.merge(fmt["tags"] || %{}, s["tags"] || %{})
         }}
    end
  end

  defp parse_probe(_), do: {:error, :bad_probe_output}

  # Lossless integer PCM containers must keep their bit depth; for everything
  # else let ffmpeg pick the encoder from the output extension.
  defp output_codec(out, original) do
    if String.downcase(Path.extname(out)) in [".wav", ".wave"] do
      bits = original_bits(original)
      codec = if bits == :float, do: "pcm_f32le", else: "pcm_s#{bits}le"
      ["-c:a", codec]
    else
      []
    end
  end

  defp original_bits(original) do
    case probe(original) do
      {:ok, %{sample_fmt: fmt, bits_per_raw_sample: raw, bits_per_sample: bps}} ->
        cond do
          fmt in ["flt", "fltp", "dbl", "dblp"] -> :float
          is_integer(raw) and raw in [16, 24, 32] -> raw
          is_integer(bps) and bps in [16, 24, 32] -> bps
          true -> 16
        end

      _ ->
        16
    end
  end

  defp add_opt(args, _flag, nil), do: args
  defp add_opt(args, flag, value), do: args ++ [flag, to_string(value)]

  defp run(exe, args) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:ffmpeg, code, out}}
    end
  rescue
    e in ErlangError -> {:error, e}
  end

  defp ffmpeg, do: Application.get_env(:tischlampe, :ffmpeg, "ffmpeg")
  defp ffprobe, do: Application.get_env(:tischlampe, :ffprobe, "ffprobe")

  defp to_int(nil), do: nil
  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)

  defp to_float(nil), do: nil
  defp to_float(v) when is_number(v), do: v * 1.0

  defp to_float(v) when is_binary(v),
    do:
      (case Float.parse(v) do
         {f, _} -> f
         :error -> nil
       end)
end
