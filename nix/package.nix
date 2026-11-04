# calibre-hub, the server binary (serve, scan, handlers, `calibre-hub cli`):
# without bubbletea.cr, so no Go library in its closure. `hub` (CLI + TUI) is
# nix/hub.nix; the flake's packages.default has both.
{
  lib,
  crystal,
  shards,
  sqlite,
  poppler-utils,
  djvulibre,
  tesseract,
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

  # shards.nix has the shards from git URLs (not bubbletea, see nix/hub.nix)
  shardsFile = ../shards.nix;
  format = "crystal";
  crystalBinaries.calibre-hub.src = "src/main.cr";
  buildInputs = [ sqlite ];
  # kemal's exception_page asks `shards version` at compile time
  nativeBuildInputs = [ shards ];
  # the specs read scans (spec/fixtures/metadata/scan.*)
  nativeCheckInputs = [
    poppler-utils
    djvulibre
    (tesseract.override {
      enableLanguages = [
        "deu"
        "eng"
      ];
    })
  ];

  postInstall = ''
    $out/bin/calibre-hub cli completion fish --prog calibre-hub > calibre-hub.fish
    $out/bin/calibre-hub cli completion bash --prog calibre-hub > calibre-hub.bash
    installShellCompletion calibre-hub.{fish,bash}
  '';

  # unit specs without the TUI's (nix/hub.nix runs those); calibre-server is
  # covered by the NixOS VM test
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    crystal spec $(ls spec/*_spec.cr | grep -v '^spec/tui_spec.cr$')
    runHook postCheck
  '';

  meta = {
    description = "Thin API, change events and web UI on top of calibre-server";
    mainProgram = "calibre-hub";
  };
}
