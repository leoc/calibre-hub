{
  lib,
  crystal,
  sqlite,
  installShellFiles,
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
  nativeBuildInputs = [ installShellFiles ];

  # `hub` is the CLI (calibre-hub cli), with completions for both names
  postInstall = ''
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
