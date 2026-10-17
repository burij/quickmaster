defmodule Quickmaster.Audio.Player do
  @moduledoc """
  Preview playback via an external `mpv` process.

  `mpv` is used instead of an HTML `<audio>` element because the desktop
  webview (wxWebView/WebKitGTK) cannot be relied on for audio output.
  """

  @doc "True when the mpv executable can be found."
  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable(mpv()))

  @doc "Start playing `path` (optionally from `:start` seconds for `:duration`)."
  @spec play(Path.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def play(path, opts \\ []) do
    args =
      ["--no-video", "--really-quiet", "--force-window=no"] ++
        option("-start", opts[:start]) ++
        option("--length", opts[:duration]) ++ [path]

    {:ok, Port.open({:spawn_executable, mpv()}, [:binary, :exit_status, args: args])}
  rescue
    e -> {:error, e}
  end

  @doc "Stop a running playback port."
  @spec stop(port()) :: :ok
  def stop(port) do
    _ = Port.command(port, "q\n")
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp option(_flag, nil), do: []
  defp option(flag, value), do: [flag, to_string(value)]

  defp mpv, do: Application.get_env(:quickmaster, :mpv, "mpv")
end
