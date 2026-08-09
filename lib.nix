{ pkgs ? import
    (fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-25.11")
    { config = { }; overlays = [ ]; }
}:

let

  appName = "tischlampe";
  appVersion = "0.1";

  beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang;

  elixirEnv = [
    beamPackages.elixir
    beamPackages.erlang
  ];

  dependencies = with pkgs; [
    wget
    git
    nixpkgs-fmt
    opencode
    wxwidgets_3_2 # wxWebView runtime used by elixir-desktop on Linux
    inotify-tools # phoenix_live_reload file watcher
  ];

  shell = pkgs.mkShell {
    buildInputs = elixirEnv ++ dependencies;
    shellHook = ''
      alias run='mix run --no-halt' 
      alias repl='iex -S mix'
      alias script='elixir ./lib/script.exs'
      alias make='rm result; nix-build'
      alias test='./result/bin/tischlampe start'
      alias form='nixpkgs-fmt default.nix; mix format'
      # @pi: why in this specific folder. i want it generic for the situation, that only this file exists, but we are working in an empty folder. should dependencies via mix not also should be installed?
      new() {
        rm -rf /tmp/tischlampe
        mix phx.new /tmp/tischlampe --app tischlampe \
          --module Tischlampe --no-ecto --no-mailer \
          --no-dashboard --no-assets
      }
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
