# The units as nix/module.nix makes them, with dmt's settings
# (hosts/dmt/ebooks.nix in nixos-config), so a new variable of the module
# comes to the dev stack by itself. dev/lib.sh writes it down and sets what
# has to differ on top. Secrets stay out: no token file of any kind is set here.
{ pkgs, nixpkgs, module }:
let
  base = "/srv/media/ebooks";
  dummy = pkgs.writeText "not-used" "";
  system = nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      module
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        services.calibre-hub = {
          enable = true;
          # the environment only names these, nothing is built here
          package = pkgs.hello;
          frontend.package = null;
          library = "${base}/calibre";
          group = "srv";
          customColumns.kategorie = {
            name = "Kategorie";
            hierarchical = true;
          };
          categoryColumn = "kategorie";
          login.passwordFile = dummy;
          sessionKeyFile = dummy;
          calibre.servicePasswordFile = dummy;
          inbox.path = "${base}/inbox";
          intake.trashDir = "${base}/papierkorb";
          leseliste = {
            enable = true;
            target = "${base}/sync/boox";
          };
          metadata.enable = true;
        };
      }
    ];
  };
in
{
  hub = system.config.systemd.services.calibre-hub.environment;
  hubWritable = system.config.systemd.services.calibre-hub.serviceConfig.ReadWritePaths;
  server = system.config.systemd.services.calibre-server.environment;
  serverCommand = system.config.systemd.services.calibre-server.serviceConfig.ExecStart;
}
