defmodule Tischlampe.Application do
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
        TischlampeWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:tischlampe, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Tischlampe.PubSub},
        Tischlampe.Session,
        TischlampeWeb.Endpoint
      ] ++ window()

    opts = [strategy: :one_for_one, name: Tischlampe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # elixir-desktop: open the native window (skipped in :test, no display there)
  defp window do
    if @start_window do
      [
        {Desktop.Window,
         [
           app: :tischlampe,
           id: TischlampeWindow,
           url: &TischlampeWeb.Endpoint.url/0
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
    TischlampeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
