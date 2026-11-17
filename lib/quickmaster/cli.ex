defmodule Quickmaster.CLI do
  @moduledoc """
  Command-line interface for controlling Quickmaster programmatically.
  Works in both headless and GUI modes.
  """

  alias Quickmaster.Session

  @doc """
  Load a file by path for a specific window.
  """
  def load_file(path, window_id \\ 1) do
    case Session.load_file(window_id, path) do
      :ok -> {:ok, "File loaded: #{path}"}
      {:error, :not_found} -> {:error, "File not found: #{path}"}
    end
  end

  @doc """
  Set a parameter value for a specific window.
  """
  def set_param(name, value, window_id \\ 1) do
    params = Session.snapshot(window_id).params
    case params do
      nil -> {:error, "No session active for window #{window_id}"}
      _params ->
        key = if is_atom(name), do: name, else: String.to_atom(name)
        new_params = Map.put(params, key, value)
        Session.set_params(window_id, new_params)
        {:ok, "Set #{key} = #{value}"}
    end
  end

  @doc """
  Toggle pregain stage for a specific window.
  """
  def toggle_pregain(window_id \\ 1) do
    params = Session.snapshot(window_id).params
    case params do
      nil -> {:error, "No session active for window #{window_id}"}
      _params ->
        new_enabled = not params.pregain_enabled
        new_params = Map.put(params, :pregain_enabled, new_enabled)
        Session.set_params(window_id, new_params)
        {:ok, "Pregain #{if(new_enabled, do: "enabled", else: "disabled")}"}
    end
  end

  @doc """
  Get current parameter value for a specific window.
  """
  def get_param(name, window_id \\ 1) do
    params = Session.snapshot(window_id).params
    case params do
      nil -> {:error, "No session active for window #{window_id}"}
      _params ->
        key = if is_atom(name), do: name, else: String.to_atom(name)
        case Map.fetch(params, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, "Unknown parameter: #{name}"}
        end
    end
  end

  @doc """
  Get all current parameters for a specific window.
  """
  def get_params(window_id \\ 1) do
    params = Session.snapshot(window_id).params
    case params do
      nil -> {:error, "No session active for window #{window_id}"}
      _params -> {:ok, params}
    end
  end

  @doc """
  Trigger preview playback for a specific window.
  """
  def preview(source \\ :master, window_id \\ 1) do
    case Session.preview(window_id, source) do
      :ok -> {:ok, "Preview started: #{source}"}
      _ -> {:error, "Could not start preview"}
    end
  end

  @doc """
  Stop preview playback for a specific window.
  """
  def stop_preview(window_id \\ 1) do
    Session.stop_preview(window_id)
    {:ok, "Preview stopped"}
  end

  @doc """
  Render/master the file to output path for a specific window.
  """
  def render(path, window_id \\ 1) do
    Session.render_to(window_id, path)
    {:ok, "Render started to #{path}"}
  end

  @doc """
  Get session status for a specific window.
  """
  def status(window_id \\ 1) do
    snap = Session.snapshot(window_id)
    {:ok, snap}
  end

  @doc """
  Reset to defaults for a specific window.
  """
  def reset(window_id \\ 1) do
    Session.set_params(window_id, Session.default_params())
    {:ok, "Reset to defaults"}
  end

  @doc """
  Wait until mastering is complete (not stale) for a specific window.
  """
  def wait_until_ready(window_id \\ 1, timeout_ms \\ 120_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_loop(window_id, deadline)
  end

  defp wait_loop(window_id, deadline) do
    snap = Session.snapshot(window_id)
    cond do
      snap.status == :ready and not snap.stale ->
        {:ok, "Ready"}
      System.monotonic_time(:millisecond) > deadline ->
        {:error, "Timeout waiting for ready"}
      true ->
        :timer.sleep(500)
        wait_loop(window_id, deadline)
    end
  end

  @doc """
  Run a full test sequence: load file, toggle params, verify.
  """
  def test_sequence(file_path, window_id \\ 1) do
    with {:ok, _} <- load_file(file_path, window_id),
         {:ok, _} <- wait_until_ready(window_id),
         {:ok, _} <- set_param(:peak_limit, -6.0, window_id),
         {:ok, _} <- wait_until_ready(window_id),
         {:ok, _} <- toggle_pregain(window_id),
         {:ok, _} <- wait_until_ready(window_id),
         {:ok, _} <- toggle_pregain(window_id),
         {:ok, _} <- wait_until_ready(window_id) do
      {:ok, "Test sequence completed"}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end