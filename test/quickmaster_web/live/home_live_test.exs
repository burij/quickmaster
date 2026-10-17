defmodule QuickmasterWeb.HomeLiveTest do
  use QuickmasterWeb.ConnCase

  alias Quickmaster.Session

  @moduletag :ffmpeg

  setup do
    Desktop.Auth.set_key(Base.encode32(:crypto.strong_rand_bytes(32)))
    Session.reset()
    :ok
  end

  test "shows the effect UI on an empty session", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}")

    assert html =~ "Quickmaster"
    assert html =~ "Dyson compressor"
    assert html =~ "Peak limit"
    assert html =~ "No file loaded"
    assert html =~ "qm-knob"
  end

  test "renders while an upload is in progress", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}")

    upload =
      file_input(view, "#qm-upload", :audio, [
        %{name: "x.wav", content: "data", type: "audio/wav"}
      ])

    assert {:ok, _} = preflight_upload(upload)

    # An unfinished entry used to crash the render (no :progress on the config).
    html = render(view)
    assert html =~ "qm-spinner"
    refute html =~ "Uploading"
  end

  test "renders the compressor once a file is loaded", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "qm_live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    input = Path.join(dir, "tone.wav")

    {_, 0} =
      System.cmd(
        Application.get_env(:quickmaster, :ffmpeg),
        ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-ac", "2", input],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(dir) end)

    Session.load(input, "tone.wav")
    wait_until(fn -> Session.snapshot().status == :ready end)

    {:ok, view, html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}")

    assert html =~ "tone.wav"
    assert html =~ "Dyson compressor"
    assert html =~ "Peak limit"
    assert html =~ "Fast ratio"
    assert html =~ "Render master"
    assert html =~ "phx-hook=\"Knob\"" or html =~ "phx-hook=Knob"

    # knob pushes a value, session params update
    assert render_hook(view, "param", %{"name" => "peak_limit", "value" => "-6"}) =~
             "Peak limit"

    wait_until(fn -> Session.snapshot().params.peak_limit == -6.0 end)

    # progress broadcasts drive the progress bar
    send(view.pid, {:session, %{Session.snapshot() | status: :mastering, phase: :master}})
    send(view.pid, {:progress, :master, 42.0})
    html = render(view)
    assert html =~ "Mastering"
    assert html =~ "42"
  end

  defp wait_until(fun, timeout \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("timed out")
      Process.sleep(30)
      do_wait(fun, deadline)
    end
  end
end
