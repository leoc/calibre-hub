# The changelog trigger installer on its own: library_db.cr plus the two
# shards it needs. calibre-server's preStart runs it, so this store path, and
# with it calibre-server's unit, only changes when the triggers can change.
{
  lib,
  crystal,
  sqlite,
  fetchgit,
  linkFarm,
}:
let
  shards = import ../shards.nix;
  lib' = linkFarm "calibre-hub-triggers-shards" (
    map (name: {
      inherit name;
      path = fetchgit shards.${name};
    }) [ "db" "sqlite3" ]
  );
in
crystal.buildCrystalPackage {
  pname = "calibre-hub-triggers";
  version = "1";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src/triggers.cr
      ../src/calibre_hub/library_db.cr
    ];
  };

  format = "crystal";
  crystalBinaries.calibre-hub-triggers.src = "src/triggers.cr";
  preBuild = "ln -s ${lib'} lib";
  buildInputs = [ sqlite ];
  # covered by spec/library_db_spec.cr in the main package
  doCheck = false;

  meta = {
    description = "Installs calibre-hub's changelog triggers into a calibre metadata.db";
    mainProgram = "calibre-hub-triggers";
  };
}
