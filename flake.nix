{
  description = "calibre-hub: thin API, events and web UI on top of calibre-server";

  # Same branch as the hosts that run it, so calibre versions match
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # Crystal bindings for Bubble Tea & co. (`hub tui`): the shard's source and
  # its Go library. Keep the tag in step with shard.yml/shard.lock.
  inputs.bubbletea-cr = {
    url = "github:leoc/bubbletea.cr/v0.2.0";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      bubbletea-cr,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (
        pkgs:
        {
          default = pkgs.callPackage ./nix/package.nix {
            bubbletea-src = bubbletea-cr;
            libbubbletea-go = bubbletea-cr.packages.${pkgs.stdenv.hostPlatform.system}.libbubbletea-go;
          };
          # what calibre-server's preStart runs (see nix/triggers.nix)
          triggers = pkgs.callPackage ./nix/triggers.nix { };
        }
        # web app, built by frontend/package.nix (Phase 3)
        // pkgs.lib.optionalAttrs (builtins.pathExists ./frontend/package.nix) {
          frontend = pkgs.callPackage ./frontend/package.nix { };
        }
      );

      # the module with the flake's package (it needs the bubbletea.cr input)
      nixosModules.default =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.calibre-hub.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

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
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
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
            poppler-utils
          ];
          QT_QPA_PLATFORM = "offscreen";
          # libbubbletea_go for `hub tui` and its specs (read at compile time)
          BUBBLETEA_LIB_DIR = "${bubbletea-cr.packages.${pkgs.stdenv.hostPlatform.system}.libbubbletea-go}/lib";
        };
      });
    };
}
