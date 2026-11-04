{
  description = "calibre-hub: thin API, events and web UI on top of calibre-server";

  # Same branch as the hosts that run it, so calibre versions match
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  # Crystal bindings for Bubble Tea & co. (`hub tui`): the shard's source and
  # its Go library, only for the hub binary. Keep the tag in step with
  # shard.yml/shard.lock.
  inputs.bubbletea-cr = {
    url = "github:leoc/bubbletea.cr/v0.2.1";
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
          # the server binary only (calibre-hub), what the NixOS module runs
          server = pkgs.callPackage ./nix/package.nix { };
          # the CLI with the TUI (hub), links bubbletea.cr's Go library
          hub = pkgs.callPackage ./nix/hub.nix {
            bubbletea-src = bubbletea-cr;
            libbubbletea-go = bubbletea-cr.packages.${pkgs.stdenv.hostPlatform.system}.libbubbletea-go;
          };
          # both, for a workstation (hub and calibre-hub cli)
          default = pkgs.symlinkJoin {
            name = "calibre-hub-0.1.0";
            paths = [
              self.packages.${pkgs.stdenv.hostPlatform.system}.server
              self.packages.${pkgs.stdenv.hostPlatform.system}.hub
            ];
            meta.mainProgram = "calibre-hub";
          };
          # what calibre-server's preStart runs (see nix/triggers.nix)
          triggers = pkgs.callPackage ./nix/triggers.nix { };
        }
        # web app, built by frontend/package.nix (Phase 3)
        // pkgs.lib.optionalAttrs (builtins.pathExists ./frontend/package.nix) {
          frontend = pkgs.callPackage ./frontend/package.nix { };
        }
      );

      # the module with the flake's server package (no bubbletea.cr, no Go)
      nixosModules.default =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.calibre-hub.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.server;
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
          package = self.packages.${pkgs.stdenv.hostPlatform.system}.server;
          hub = self.packages.${pkgs.stdenv.hostPlatform.system}.hub;
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
            djvulibre
            tesseract
          ];
          QT_QPA_PLATFORM = "offscreen";
          # libbubbletea_go for `hub tui` and its specs (read at compile time)
          BUBBLETEA_LIB_DIR = "${bubbletea-cr.packages.${pkgs.stdenv.hostPlatform.system}.libbubbletea-go}/lib";
        };
      });
    };
}
