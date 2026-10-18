{ pkgs ? import
    (fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-25.11")
    { config = { }; overlays = [ ]; }
}:

let

  appName = "quickmaster";
  appVersion = "0.1";

  beamPackages = pkgs.beam27Packages;

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
    ffmpeg-headless # decode/encode any audio format
    mpv # preview playback
  ];

  shell = pkgs.mkShell {
    buildInputs = elixirEnv ++ dependencies;
    shellHook = ''
      alias run='mix run --no-halt' 
      alias repl='iex -S mix'
      alias script='elixir ./lib/script.exs'
      alias make='rm result; nix-build'
      alias test='./result/bin/${appName} start'
      alias form='nixpkgs-fmt default.nix; mix format'
      # regenerates the phoenix boilerplate in the current (empty) folder;
      # app/module names are derived from the folder name
      new() {
        app=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' |
          sed 's/[^a-z0-9]//g; s/^[0-9]*//')
        app=''${app:-app}
        module=$(basename "$PWD" |
          sed 's/[^A-Za-z0-9]//g; s/^[0-9]*//; s/^\([a-z]\)/\U\1/')
        module=''${module:-App}
        printf 'y\n' | mix phx.new . --app "$app" --module "$module" \
          --no-ecto --no-mailer --no-dashboard --no-assets --install
      }
    '';
  };

  release = beamPackages.mixRelease {
    pname = appName;
    version = appVersion;
    src = ./.;
    removeCookie = false;
  };

  # The release binary is named after the OTP app (:quickmaster). Wrap it so
  # the audio tools (and wxWidgets/GTK) are on PATH at runtime.
  # Also need GTK settings schemas for the file chooser to work.
  runtimePath = pkgs.lib.makeBinPath (
    with pkgs; [
      ffmpeg-headless
      mpv
      wxwidgets_3_2
      gtk3
    ]
  );

  # GSettings schema directory for GTK file chooser
  # Must point to directory containing schema source subdirs (each with glib-2.0/schemas/)
  gsettingsSchemaDir = pkgs.lib.makeSearchPath "share/gsettings-schemas" (
    with pkgs; [
      gtk3
    ]
  );

  # XDG_DATA_DIRS for WebKitGTK WebProcess - must point to directories containing
  # glib-2.0/schemas/ (the schema source dirs, not the share root)
  gtkSchemaDir = "${pkgs.gtk3}/share/gsettings-schemas/gtk+3-3.24.52";
  desktopSchemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/gsettings-desktop-schemas-50.1";
  xdgDataDirs = "${gtkSchemaDir}:${desktopSchemaDir}";

  package = pkgs.runCommand appName
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
    } ''
    mkdir -p $out/bin
    makeWrapper ${release}/bin/quickmaster $out/bin/quickmaster \
      --prefix PATH : ${runtimePath} \
      --set GSETTINGS_SCHEMA_DIR ${gsettingsSchemaDir} \
      --prefix XDG_DATA_DIRS : ${xdgDataDirs}
  '';


in
{ shell = shell; package = package; }