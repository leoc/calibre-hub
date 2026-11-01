{
  lib,
  crystal,
  sqlite,
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

  shardsFile = ../shards.nix;
  format = "shards";
  buildInputs = [ sqlite ];

  # unit specs only; calibre-server is covered by the NixOS VM test
  doCheck = true;

  meta = {
    description = "Thin API, change events and web UI on top of calibre-server";
    mainProgram = "calibre-hub";
  };
}
