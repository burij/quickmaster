defmodule Quickmaster.SessionSupervisor do
  @moduledoc """
  Manages per-window Session processes using a simple GenServer registry.

  Each window gets its own Session instance, tracked in a map.
  PubSub topic is `"qm:session:<window_id>"`.
  """

  use GenServer

  alias Quickmaster.Session

  @impl true
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @doc """
  Start a new session for `window_id`.
  Returns `{:ok, pid}` or `{:error, :already_started}`.
  """
  def start_session(window_id) do
    # Ensure the GenServer is running
    case GenServer.whereis(__MODULE__) do
      nil ->
        # Start the GenServer if not running
        {:ok, _pid} = GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
      _pid ->
        :ok
    end
    GenServer.call(__MODULE__, {:start_session, window_id})
  end

  @impl true
  def handle_call({:start_session, window_id}, _from, sessions) do
    if Map.has_key?(sessions, window_id) do
      {:reply, {:error, :already_started}, sessions}
    else
      {:ok, pid} = Session.start_link(window_id)
      {:reply, {:ok, pid}, Map.put(sessions, window_id, pid)}
    end
  end

  @doc """
  Get the Session PID for `window_id`.
  """
  def session_pid(window_id) do
    GenServer.call(__MODULE__, {:session_pid, window_id})
  end

  @impl true
  def handle_call({:session_pid, window_id}, _from, sessions) do
    {:reply, Map.fetch(sessions, window_id), sessions}
  end

  @doc """
  Stop the session for `window_id`.
  """
  def stop_session(window_id) do
    GenServer.call(__MODULE__, {:stop_session, window_id})
  end

  @impl true
  def handle_call({:stop_session, window_id}, _from, sessions) do
    case Map.pop(sessions, window_id) do
      {pid, sessions} ->
        Process.exit(pid, :kill)
        {:reply, {:ok, pid}, sessions}
      :error ->
        {:reply, {:error, :not_found}, sessions}
    end
  end

  @doc """
  List all active window_ids.
  """
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @impl true
  def handle_call(:list_sessions, _from, sessions) do
    {:reply, Map.keys(sessions), sessions}
  end

  def via(window_id), do: {:via, Registry, {Quickmaster.SessionRegistry, window_id}}
end