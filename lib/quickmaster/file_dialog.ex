defmodule Quickmaster.FileDialog do
  @moduledoc """
  Native save dialog via `wxFileDialog`.

  Returns `nil` when the dialog is cancelled or unavailable (for example in
  tests, where no wx window exists), so callers must handle that.
  """

  import Bitwise

  require Logger

  # wxFD_SAVE | wxFD_OVERWRITE_PROMPT
  @save_style 2 ||| 4
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

  defp show(options) do
    frame = Desktop.Window.frame(QuickmasterWindow)
    dialog = :wxFileDialog.new(frame, options)
    result = :wxFileDialog.showModal(dialog)
    path = if result == @ok, do: List.to_string(:wxFileDialog.getPath(dialog))
    :wxFileDialog.destroy(dialog)
    path
  rescue
    e ->
      Logger.error("file dialog failed: #{inspect(e)}")
      nil
  end
end
