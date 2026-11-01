{
  description = "calibre-hub: thin API, events and web UI on top of calibre-server";

  # Same branch as the hosts that run it, so calibre versions match
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      nixosModules.default = ./nix/module.nix;

      # slow, not part of `nix flake check`: nix build .#scale-test -L
      scale-test = import ./nix/scale-test.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        module = self.nixosModules.default;
      };

      checks = forAll (pkgs: {
        package = self.packages.${pkgs.system}.default;
        vm = import ./nix/test.nix {
          inherit pkgs;
          module = self.nixosModules.default;
        };
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
