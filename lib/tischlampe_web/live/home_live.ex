defmodule TischlampeWeb.HomeLive do
  use TischlampeWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Hello world</h1>
    <p>Tischlampe läuft als LiveView-Desktop-App (elixir-desktop).</p>
    """
  end
end