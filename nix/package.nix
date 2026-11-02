{
  lib,
  crystal,
  sqlite,
  installShellFiles,
  # bubbletea.cr (shard source) and its Go library, from the flake input
  bubbletea-src,
  libbubbletea-go,
}:
crystal.buildCrystalPackage {
  pname = "calibre-hub";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../shard.yml
      ../shard.lock
      ../src
      ../spec
    ];
  };

  # shards.nix has the shards from git URLs; bubbletea comes from the flake
  # input, which also builds its Go library (linked with an rpath)
  shardsFile = ../shards.nix;
  postConfigure = ''
    ln -s ${bubbletea-src} lib/bubbletea
  '';
  env.BUBBLETEA_LIB_DIR = "${libbubbletea-go}/lib";
  format = "shards";
  buildInputs = [ sqlite ];
  nativeBuildInputs = [ installShellFiles ];

  # `hub` is the CLI (calibre-hub cli), with completions for both names
  postInstall = ''
    # bubbletea.cr always adds an rpath to its own go/build (empty here, the
    # library comes from BUBBLETEA_LIB_DIR): keep only store paths
    chmod u+w $out/bin/calibre-hub
    patchelf --shrink-rpath --allowed-rpath-prefixes ${builtins.storeDir} $out/bin/calibre-hub
    chmod u-w $out/bin/calibre-hub
    ln -s calibre-hub $out/bin/hub
    for prog in hub calibre-hub; do
      $out/bin/calibre-hub cli completion fish --prog $prog > $prog.fish
      $out/bin/calibre-hub cli completion bash --prog $prog > $prog.bash
    done
    installShellCompletion --fish hub.fish calibre-hub.fish --bash hub.bash calibre-hub.bash
  '';

  # unit specs only; calibre-server is covered by the NixOS VM test
  doCheck = true;

  meta = {
    description = "Thin API, change events and web UI on top of calibre-server";
    mainProgram = "calibre-hub";
  };
}
