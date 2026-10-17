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

  import Bitwise

  # wxFD_OPEN | wxFD_FILE_MUST_EXIST
  @dialog_style 1 ||| 16
  @wildcard "Audio files|*.wav;*.mp3;*.flac;*.ogg;*.oga;*.opus;*.m4a;*.aac;*.aiff;*.aif|All files|*"

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
    frame = Desktop.Window.frame(QuickmasterWindow)

    dialog =
      :wxFileDialog.new(frame,
        message: "Open audio file",
        wildCard: @wildcard,
        style: @dialog_style
      )

    result = :wxFileDialog.showModal(dialog)
    path = if result == 5100, do: List.to_string(:wxFileDialog.getPath(dialog)), else: nil
    :wxFileDialog.destroy(dialog)

    if path, do: Quickmaster.Session.load_file(path)
    :ok
  rescue
    e ->
      require Logger
      Logger.error("native open dialog failed: #{inspect(e)}")
      :ok
  end
end
