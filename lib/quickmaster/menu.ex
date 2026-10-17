defmodule Quickmaster.Menu do
  @moduledoc """
  Native menu bar.

  "Open audio file…" uses a native file dialog and hands the chosen path
  straight to `Quickmaster.Session` (no upload). This is the reliable way to
  open a file: HTML5 drag and drop does not work in the wxWebView on Linux,
  because the GTK widget is a drop destination and swallows the drag before
  WebKit can deliver it to the page.
  """

  use Desktop.Menu

  @impl true
  def mount(menu), do: {:ok, menu}

  @impl true
  def handle_event("open", menu) do
    open_dialog()
    {:noreply, menu}
  end

  def handle_event("quit", menu) do
    Desktop.Window.quit()
    {:noreply, menu}
  end

  def handle_event(_command, menu), do: {:noreply, menu}

  @impl true
  def handle_info(_msg, menu), do: {:noreply, menu}

  @impl true
  def render(assigns) do
    ~H"""
    <menubar>
      <menu label="File">
        <item onclick="open">Open audio file…</item>
        <hr />
        <item onclick="quit">Quit</item>
      </menu>
    </menubar>
    """
  end

  defp open_dialog do
    case Quickmaster.FileDialog.open() do
      nil -> :ok
      path -> Quickmaster.Session.load_file(path)
    end
  end
end
