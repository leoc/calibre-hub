# NixOS VM test: calibre-server + calibre-hub from the module, an empty
# library, one book added through calibre-server. Also the smoke test against
# the calibre version of the pinned nixpkgs.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "calibre-hub";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ module ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        pkgs.calibre
        pkgs.curl
        pkgs.jq
      ];
      environment.etc = {
        "hub/service".text = "service-secret";
        "hub/login".text = "login-secret\n";
        "hub/key".text = "0123456789abcdef0123456789abcdef";
        "hub/scripts".text = "scripts-secret";
      };
      services.calibre-hub = {
        enable = true;
        library = "/srv/books/library";
        customColumns.kategorie = {
          name = "Kategorie";
          hierarchical = true;
        };
        categoryColumn = "kategorie";
        login.passwordFile = "/etc/hub/login";
        sessionKeyFile = "/etc/hub/key";
        calibre.servicePasswordFile = "/etc/hub/service";
        calibre.extraUsers.scripts = "/etc/hub/scripts";
      };
      systemd.tmpfiles.rules = [ "d /srv/books/library 2775 calibre-server calibre-hub -" ];
    };

  testScript = ''
    import json

    H = "http://127.0.0.1:8084"
    CSRF = "-H 'X-Calibre-Hub: 1'"
    LIB = "'http://127.0.0.1:8083/#library'"
    DB = "calibredb --with-library " + LIB + " --username scripts --password scripts-secret"

    def code(args):
        return machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {args}").strip()

    machine.wait_for_unit("calibre-server.service")
    machine.wait_for_open_port(8083, timeout=120)
    machine.wait_for_unit("calibre-hub.service")
    machine.wait_for_open_port(8084)

    with subtest("calibre-server prepared by init.sh"):
        machine.succeed("calibredb --with-library " + LIB + " --username calibre-hub --password service-secret custom_columns | grep -q '^kategorie '")
        # Basic only, localhost only
        machine.fail("ss -ltn | grep -q '0.0.0.0:8083'")

    with subtest("login"):
        assert code(f"{H}/api/books") == "401"
        assert code(f"-X POST -d '{{\"user\":\"arthur\",\"password\":\"login-secret\"}}' {H}/api/session") == "403"
        assert code(f"-X POST {CSRF} -d '{{\"user\":\"arthur\",\"password\":\"nope\"}}' {H}/api/session") == "401"
        assert code(f"-c /tmp/jar -X POST {CSRF} -d '{{\"user\":\"arthur\",\"password\":\"login-secret\"}}' {H}/api/session") == "200"

    with subtest("books, filters, categories"):
        machine.succeed("printf 'Testbuch\\n\\nInhalt\\n' > /tmp/b.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/b.txt /tmp/b.epub --title Testbuch --authors 'Ada Lovelace'")
        machine.succeed(f"{DB} add /tmp/b.epub")
        machine.succeed(f"{DB} set_custom kategorie 1 Fachbuch.Software")
        machine.succeed(f"{DB} set_metadata 1 -f tags:leseliste")
        books = json.loads(machine.succeed(f"curl -sf -b /tmp/jar '{H}/api/books?kategorie=Fachbuch'"))
        assert books["total"] == 1, books
        b = books["books"][0]
        assert b["title"] == "Testbuch" and b["seriesIndex"] is None and b["custom"]["kategorie"] == "Fachbuch.Software", b
        cats = json.loads(machine.succeed(f"curl -sf -b /tmp/jar {H}/api/categories"))
        assert cats["kategorie"][0]["path"] == "Fachbuch" and cats["kategorie"][0]["count"] == 1, cats
        assert code(f"-b /tmp/jar {H}/api/books/1/download/epub") == "200"
        assert code(f"-b /tmp/jar '{H}/api/books/1/cover?size=thumb'") == "200"

    with subtest("events"):
        machine.wait_until_succeeds("journalctl -u calibre-hub -o cat | grep '\"type\":\"changed\"' | grep -q leseliste", timeout=30)

    with subtest("opds with basic auth"):
        assert code(f"{H}/opds") == "401"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"

    with subtest("calibre-server down -> 502"):
        machine.systemctl("stop calibre-server.service")
        assert code(f"-b /tmp/jar {H}/api/books") == "502"
  '';
}
