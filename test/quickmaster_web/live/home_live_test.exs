defmodule QuickmasterWeb.HomeLiveTest do
  use QuickmasterWeb.ConnCase

  alias Quickmaster.Session

  @moduletag :ffmpeg

  setup do
    Desktop.Auth.set_key(Base.encode32(:crypto.strong_rand_bytes(32)))
    window_id = System.unique_integer([:positive])
    {:ok, _pid} = Quickmaster.SessionSupervisor.start_session(window_id)
    on_exit(fn -> Quickmaster.SessionSupervisor.stop_session(window_id) end)
    {:ok, window_id: window_id}
  end

  test "shows the effect UI on an empty session", %{conn: conn, window_id: window_id} do
    Session.reset(window_id)
    {:ok, view, html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}&window_id=#{window_id}")

    assert html =~ "Quickmaster"
    assert html =~ "Dyson compressor"
    assert html =~ "Peak limit"
    assert html =~ "No file loaded"
    assert html =~ "qm-knob"

    # saving is impossible without a finished master
    assert render(view) =~ ~r/id="qm-save"[^>]*disabled/
  end

  test "renders while an upload is in progress", %{conn: conn, window_id: window_id} do
    Session.reset(window_id)
    {:ok, view, _html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}&window_id=#{window_id}")

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

  test "renders the compressor once a file is loaded", %{conn: conn, window_id: window_id} do
    Session.reset(window_id)
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

    Session.load(window_id, input, "tone.wav")
    wait_until(fn -> Session.snapshot(window_id).status == :ready end)
    wait_until(fn -> not Session.snapshot(window_id).stale end)

    {:ok, view, html} = live(conn, ~p"/?k=#{Desktop.Auth.login_key()}&window_id=#{window_id}")

    assert html =~ "tone.wav"
    assert html =~ "Original · 30 s"
    assert html =~ "Mastered · 30 s"
    assert html =~ "Save"
    refute render(view) =~ ~r/id="qm-save"[^>]*disabled/
    assert html =~ "Dyson compressor"
    assert html =~ "Peak limit"
    assert html =~ "Fast ratio"
    assert html =~ "phx-hook=\"Knob\"" or html =~ "phx-hook=Knob"

    # knob pushes a value, session params update
    assert render_hook(view, "param", %{"name" => "peak_limit", "value" => "-6"}) =~
             "Peak limit"

    wait_until(fn -> Session.snapshot(window_id).params.peak_limit == -6.0 end)

    # progress broadcasts drive the progress bar
    snap = %{Session.snapshot(window_id) | status: :mastering, phase: :master_full}
    send(view.pid, {:session, snap})
    send(view.pid, {:progress, :master_full, 42.0})
    html = render(view)
    assert html =~ "Mastering"
    assert html =~ "42"

    # the preview phase has its own label
    send(view.pid, {:progress, :master_preview, 10.0})
    assert render(view) =~ "Rendering preview"
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