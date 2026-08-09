# Tischlampe — LiveView-Desktop-App

Phoenix LiveView app running in a native window via
[elixir-desktop/desktop](https://github.com/elixir-desktop/desktop)
(`Desktop.Window` + wxWebView). No custom JS/CSS pipeline: the LiveView
client ships precompiled in `priv/static/assets/js/app.js` (copied from
`deps/phoenix_live_view/priv/static/phoenix_live_view.js`), so **nodejs is
not needed**.

## Development

    nix-shell            # project shell (elixir, erlang, wxGTK32, ...)
    run                  # mix run --no-halt; the wx window opens
    repl                 # iex -S mix
    test                 # mix test
    make                 # nix-build -A package && git add . && git commit -m
    form                 # nixpkgs-fmt; mix format

## Project layout

- `lib/tischlampe_web/live/home_live.ex` — the LiveView home ("Hello world")
- `lib/tischlampe/application.ex` — starts the endpoint + `Desktop.Window`
  (window skipped in `:test`, compile-time `@start_window` attr)
- `lib/tischlampe_web/endpoint.ex` — `Desktop.Endpoint` + `Desktop.Auth`
  plug (only the desktop window may access the app)
- `config/runtime.exs` — prod: endpoint on `http://localhost:4000`
  (loopback only, no TLS — it is a local desktop app)
- `config/dev.exs` — dev: `server: true`, port 4000, window auto-opens

## Release

    nix-build -A package
    PHX_SERVER=true SECRET_KEY_BASE=<secret> ./result/bin/tischlampe start

## Desktop auth

`Desktop.Auth` returns 401 unless the request carries the per-boot key as
`?k=...` (the window adds it automatically). The test sets the key via
`Desktop.Auth.set_key/1` and uses `Desktop.Auth.login_key/0`.