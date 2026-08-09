{ pkgs ? import
    (fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-25.11")
    { config = { }; overlays = [ ]; }
}:

let

  appName = "tischlampe";
  appVersion = "0.1";

  elixirEnv = with pkgs; [
    elixir
    erlang
  ];

  beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang;

  # elixir-desktop (LiveView desktop): npm for the JS wrapper,
  # wxGTK32 brings the wxWebView runtime on Linux (erlang is
  # built with --enable-wx using the same wxWidgets).
  dependencies = with pkgs; [
    wget
    git
    nixpkgs-fmt
    opencode
    wxGTK32
    inotify-tools # phoenix_live_reload file watcher
  ];

  shell = pkgs.mkShell {
    buildInputs = elixirEnv ++ dependencies;
    shellHook = ''
      alias run='mix run --no-halt' # boots the app; desktop window opens on Application.start
      alias repl='iex -S mix'
      alias script='elixir ./lib/script.exs'
      alias make='nix-build -A package && git add . && git commit -m '
      alias form='nixpkgs-fmt default.nix; mix format'
    '';
  };

  package = beamPackages.mixRelease {
    pname = appName;
    version = appVersion;
    src = ./.;
    removeCookie = false;
  };


in
{ shell = shell; package = package; }
