defmodule TischlampeWeb.HomeLiveTest do
  use TischlampeWeb.ConnCase

  test "GET / renders hello world", %{conn: conn} do
    Desktop.Auth.set_key(Base.encode32(:crypto.strong_rand_bytes(32)))

    conn = get(conn, ~p"/?k=#{Desktop.Auth.login_key()}")
    assert html_response(conn, 200) =~ "Hello world"
  end
end