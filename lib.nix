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
