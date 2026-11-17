defmodule Quickmaster.Application do
  @moduledoc false

  use Application

  # Compile-time: no Mix module inside releases. Test env has no display.
  # Headless mode: set QUICKMASTER_HEADLESS=true to skip window
  @start_window Mix.env() != :test and System.get_env("QUICKMASTER_HEADLESS") != "true"

  @impl true
  def start(_type, _args) do
    children =
      [
        QuickmasterWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:quickmaster, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Quickmaster.PubSub},
        Quickmaster.SessionSupervisor,
        QuickmasterWeb.Endpoint
      ] ++ window()

    opts = [strategy: :one_for_one, name: Quickmaster.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initialize main window class for GNOME taskbar icon
    if @start_window do
      init_main_window_class()
    end
    {:ok, pid}
  end

  # elixir-desktop: open the native window (skipped in :test, no display there)
  defp window do
    if @start_window do
      [
        {Desktop.Window,
         [
           app: :quickmaster,
           id: QuickmasterWindow,
           title: "Quickmaster",
           # icon path is relative to priv/
           icon: "static/images/icon.png",
           taskbar_icon: "static/images/icon.png",
           # large enough to show the whole panel without scrolling
           size: {1180, 885},
           min_size: {1000, 760},
           url: &QuickmasterWeb.Endpoint.url/0
         ]}
      ]
    else
      []
    end
  end

  @doc "Initialize the main window's class for GNOME taskbar icon."
  defp init_main_window_class do
    Desktop.Platform.Helpers.with_wx_env(fn ->
      frame = Desktop.Window.frame(QuickmasterWindow)
      :'wxFrame'.setName(frame, "QuickmasterWindow")
    end)
  end

  @doc "Start a new window with its own session. Returns {:ok, window_id} or {:error, reason}."
  def new_window(window_id \\ System.unique_integer([:positive])) do
    # Start the session for this window
    case Quickmaster.SessionSupervisor.start_session(window_id) do
      {:ok, _pid} ->
        # Start the native window in a separate process
        Task.start(fn ->
          Desktop.Platform.Helpers.with_wx_env(fn ->
            {:ok, _pid} = Desktop.Window.start_link(
              app: :quickmaster,
              id: window_id,
              title: "Quickmaster",
              icon: "static/images/icon.png",
              taskbar_icon: "static/images/icon.png",
              size: {1180, 885},
              min_size: {1000, 760},
              url: &QuickmasterWeb.Endpoint.url/0
            )
            # Set window class explicitly for GNOME taskbar icon
            frame = Desktop.Window.frame(window_id)
            :'wxFrame'.setName(frame, window_id)
          end)
        end)
        {:ok, window_id}
      {:error, :already_started} ->
        {:error, :already_started}
      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QuickmasterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end