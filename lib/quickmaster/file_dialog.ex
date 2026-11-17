defmodule Quickmaster.FileDialog do
  @moduledoc """
  Native file dialogs via `wxFileDialog`.

  Returns `nil` when the dialog is cancelled or unavailable (for example in
  tests, where no wx window exists), so callers must handle that.
  """

  import Bitwise

  require Logger

  # wxFD_SAVE | wxFD_OVERWRITE_PROMPT
  @save_style 2 ||| 4
  # wxFD_OPEN | wxFD_FILE_MUST_EXIST
  @open_style 1 ||| 16
  @ok 5100

  @wildcard "Audio files|*.wav;*.mp3;*.flac;*.ogg;*.oga;*.opus;*.m4a;*.aac;*.aiff;*.aif|All files|*"

  @doc "Native save dialog pre-filled with `default_path`; returns path or nil."
  @spec save(Path.t()) :: String.t() | nil
  def save(default_path) do
    show(
      message: "Save master as",
      wildCard: @wildcard,
      defaultDir: Path.dirname(default_path),
      defaultFile: Path.basename(default_path),
      style: @save_style
    )
  end

  @doc "Native open dialog; returns path or nil."
  @spec open() :: String.t() | nil
  def open do
    show(
      message: "Open audio file",
      wildCard: @wildcard,
      defaultDir: default_open_dir(),
      style: @open_style
    )
  end

  defp show(options) do
    # wx APIs need the active wx env in the *calling* process.
    Desktop.Platform.Helpers.with_wx_env(fn ->
      frame = Desktop.Window.frame(QuickmasterWindow)
      dialog = :wxFileDialog.new(frame, options)
      result = :wxFileDialog.showModal(dialog)
      path = if result == @ok, do: List.to_string(:wxFileDialog.getPath(dialog))
      :wxFileDialog.destroy(dialog)
      path
    end)
  rescue
    e ->
      Logger.error("file dialog failed: #{inspect(e)}")
      nil
  end

  defp default_open_dir do
    home = System.user_home() || System.tmp_dir!()

    Enum.find(
      [Path.join(home, "Music"), Path.join(home, "Downloads"), home],
      System.tmp_dir!(),
      &File.dir?/1
    )
  end
end