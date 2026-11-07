# What the dev stack runs on, from the nixpkgs dmt runs on (dev/lib.sh finds
# the revision): the same calibre and the same tools the module puts on the
# hub's path, plus what only the dev stack needs. Not part of the flake.
{ pkgs }:
pkgs.buildEnv {
  name = "calibre-hub-dev-tools";
  paths = with pkgs; [
    # as in nix/module.nix
    calibre
    poppler-utils
    djvulibre
    (tesseract.override {
      enableLanguages = [
        "deu"
        "eng"
      ];
    })
    gnugrep
    gnused
    # the sandbox, the door for devices
    bubblewrap
    socat
    # the shell inside the sandbox
    bashInteractive
    coreutils
    findutils
    gawk
    sqlite
    # the demo files
    imagemagick
    python3
  ];
}
