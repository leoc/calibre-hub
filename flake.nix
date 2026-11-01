{
  description = "calibre-hub: thin API, events and web UI on top of calibre-server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            crystal
            shards
            crystal2nix
            calibre
            sqlite
            curl
            jq
          ];
          QT_QPA_PLATFORM = "offscreen";
        };
      });
    };
}
