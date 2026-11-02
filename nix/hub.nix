# hub: the command line client with the TUI (src/hub.cr). Links bubbletea.cr's
# Go library, which is why it is not part of the server binary.
{
  lib,
  crystal,
  # bubbletea.cr (shard source) and its Go library, from the flake input
  bubbletea-src,
  libbubbletea-go,
}:
crystal.buildCrystalPackage {
  pname = "calibre-hub-cli";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../spec/tui_spec.cr
    ];
  };

  # the client needs no shard but bubbletea, which comes from the flake input
  format = "crystal";
  crystalBinaries.hub.src = "src/hub.cr";
  postConfigure = ''
    mkdir -p lib
    ln -s ${bubbletea-src} lib/bubbletea
  '';
  env.BUBBLETEA_LIB_DIR = "${libbubbletea-go}/lib";

  postInstall = ''
    # bubbletea.cr always adds an rpath to its own go/build (empty here, the
    # library comes from BUBBLETEA_LIB_DIR): keep only store paths
    chmod u+w $out/bin/hub
    patchelf --shrink-rpath --allowed-rpath-prefixes ${builtins.storeDir} $out/bin/hub
    chmod u-w $out/bin/hub
    $out/bin/hub completion fish --prog hub > hub.fish
    $out/bin/hub completion bash --prog hub > hub.bash
    installShellCompletion hub.{fish,bash}
  '';

  # the CLI's specs run with the server package (they need no TUI)
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    crystal spec spec/tui_spec.cr
    runHook postCheck
  '';

  meta = {
    description = "calibre-hub command line client and terminal UI";
    mainProgram = "hub";
  };
}
