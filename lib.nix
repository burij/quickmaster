{ pkgs ? import
    (fetchTarball "https://github.com/NixOS/nixpkgs/tarball/nixos-26.05")
    { config = { }; overlays = [ ]; }

  # false: build this checkout (src = ./.); true: fetch the release archive
, fromUpstream ? false
  # tag/rev to fetch; defaults to VERSION
, upstreamRev ? null
  # empty means: let nix print the correct hash on the next build
, upstreamSha256 ? ""
}:

let

  appName = "quickmaster";
  appVersion = pkgs.lib.removeSuffix "\n" (builtins.readFile ./VERSION);

  beamPackages = pkgs.beam27Packages;

  elixirEnv = [
    beamPackages.elixir
    beamPackages.erlang
  ];

  dependencies = with pkgs; [
    wget
    git
    nixpkgs-fmt
    wxwidgets_3_2 # wxWebView runtime used by elixir-desktop on Linux
    inotify-tools # phoenix_live_reload file watcher
    ffmpeg-headless # decode/encode any audio format
    mpv # preview playback
  ];

  shell = pkgs.mkShell {
    buildInputs = elixirEnv ++ dependencies;
    shellHook = ''
      export GTK_THEME=Adwaita:dark
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

  srcRev = if upstreamRev == null then appVersion else upstreamRev;

  # Default is the checkout, so a clone builds with no hashes at all (a hash
  # inside the tree it hashes cannot be satisfied). Pinning the release
  # archive is the caller's job: set fromUpstream and pass upstreamSha256.
  src =
    if fromUpstream then
      pkgs.fetchFromGitHub {
        owner = "burij";
        repo = "quickmaster";
        rev = srcRev;
        sha256 = if upstreamSha256 == "" then pkgs.lib.fakeSha256 else upstreamSha256;
      }
    else
      pkgs.lib.cleanSourceWith {
        src = ./.;
        filter =
          path: _type:
          !(builtins.elem (baseNameOf path) [ "_build" "deps" "result" ]);
      };

  mixDeps = beamPackages.fetchMixDeps {
    pname = "${appName}-deps";
    version = appVersion;
    inherit src;
    hash = "sha256-/gKFne66TpXX2z5Wf+Ei4vvnPjeKlcposd4TzqAOTig=";
  };

  release = beamPackages.mixRelease {
    pname = appName;
    version = appVersion;
    inherit src;
    mixFodDeps = mixDeps;
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
  schemaOwners = with pkgs; [ gtk3 gsettings-desktop-schemas ];

  # glib searches GSETTINGS_SCHEMA_DIR for gschemas.compiled, which lives in
  # …/gsettings-schemas/<pkg>/glib-2.0/schemas (getSchemaPath returns exactly
  # that). Pointing one level higher silently loses the schemas, e.g.
  # org.gtk.Settings.FileChooser, and GTK aborts on the file chooser.
  schemaPaths = map pkgs.glib.getSchemaPath schemaOwners;
  gsettingsSchemaDir = pkgs.lib.concatStringsSep ":" schemaPaths;

  # XDG_DATA_DIRS (WebKitGTK WebProcess) wants the parent that holds
  # glib-2.0/schemas, i.e. the same path without the schema suffix.
  xdgDataDirs = pkgs.lib.concatStringsSep ":" (
    map (pkgs.lib.removeSuffix "/glib-2.0/schemas") schemaPaths
  );

  package = pkgs.runCommand appName
    {
      nativeBuildInputs = [ pkgs.makeWrapper pkgs.desktop-file-utils ];
    } ''
    mkdir -p $out/bin
    makeWrapper ${release}/bin/quickmaster $out/bin/quickmaster \
      --prefix PATH : ${runtimePath} \
      --set GSETTINGS_SCHEMA_DIR ${gsettingsSchemaDir} \
      --prefix XDG_DATA_DIRS : ${xdgDataDirs} \
      --set GTK_THEME Adwaita:dark

    # Install desktop entry for application menu
    mkdir -p $out/share/applications
    cat > $out/share/applications/${appName}.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Quickmaster
GenericName=Audio Mastering
Comment=Fast audio mastering with Dyson compressor
Exec=quickmaster start
Icon=quickmaster
Terminal=false
Categories=AudioVideo;AudioEditing;
StartupNotify=true
StartupWMClass=QuickmasterWindow
EOF

    # Install icon in hicolor theme (256px from priv/static/images/icon.png)
    mkdir -p $out/share/icons/hicolor/256x256/apps
    cp ${src}/priv/static/images/icon.png $out/share/icons/hicolor/256x256/apps/${appName}.png
  '';


in
{ shell = shell; package = package; }