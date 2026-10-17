defmodule Quickmaster.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Compile-time: no Mix module inside releases. Test env has no display.
  @start_window Mix.env() != :test

  @impl true
  def start(_type, _args) do
    children =
      [
        QuickmasterWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:quickmaster, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Quickmaster.PubSub},
        Quickmaster.Session,
        QuickmasterWeb.Endpoint
      ] ++ window()

    opts = [strategy: :one_for_one, name: Quickmaster.Supervisor]
    Supervisor.start_link(children, opts)
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
           # large enough to show the whole panel without scrolling
           size: {1180, 800},
           min_size: {1000, 680},
           url: &QuickmasterWeb.Endpoint.url/0
         ]}
      ]
    else
      []
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
