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
        pkgs.sqlite
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
        inbox = {
          path = "/srv/books/inbox";
          stableSeconds = 2;
        };
        leseliste = {
          enable = true;
          target = "/srv/books/boox";
        };
        handlerAttempts = 2;
        alertCommand = "${pkgs.writeShellScript "alert" ''echo "$1: $2" >> /var/lib/calibre-hub/alerts.log''}";
        handlers = {
          "10-log" = pkgs.writeShellScript "log" ''${pkgs.jq}/bin/jq -c '[.type, .bookId, (.changes // {} | keys)]' >> /var/lib/calibre-hub/events.log'';
          "90-fail" = pkgs.writeShellScript "fail" ''! ${pkgs.jq}/bin/jq -e '.book.title == "Kaputt"' >/dev/null'';
        };
      };
      systemd.tmpfiles.rules = [
        "d /srv/books/library 2775 calibre-server calibre-hub -"
        "d /srv/books/inbox 2775 root calibre-hub -"
        "d /srv/books/boox 2775 root calibre-hub -"
      ];
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

    with subtest("trigger changelog"):
        n = machine.succeed("sqlite3 /srv/books/library/metadata.db \"select count(*) from sqlite_master where type = 'trigger' and name like 'hub_%'\"").strip()
        assert int(n) > 10, n
        machine.succeed("sqlite3 /srv/books/library/metadata.db 'select count(*) from hub_changelog' | grep -qv '^0$'")

    with subtest("events reach handlers"):
        machine.wait_until_succeeds("grep -q '\"changed\",1,.*tags' /var/lib/calibre-hub/events.log", timeout=30)

    with subtest("reading list"):
        machine.wait_until_succeeds("test -f '/srv/books/boox/Fachbuch/Software/Lovelace, Ada - Testbuch.epub'", timeout=30)
        machine.succeed(f"{DB} set_metadata 1 -f tags:")
        machine.wait_until_succeeds("! find /srv/books/boox -name '*.epub' | grep -q .", timeout=30)

    with subtest("inbox"):
        machine.succeed("printf 'Krimi\\n\\nText\\n' > /tmp/k.txt")
        # a folder without group write is skipped, not imported twice
        machine.succeed("mkdir -m 755 /srv/books/inbox/Privat && cp /tmp/b.epub /srv/books/inbox/Privat/")
        machine.wait_until_succeeds("journalctl -u calibre-hub -o cat | grep -q 'Privat/b.epub skipped'", timeout=30)
        # like Samba on dmt: directory mask 2775
        machine.succeed("install -d -m 2775 -g calibre-hub /srv/books/inbox/Roman /srv/books/inbox/Roman/Krimi")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/k.txt /srv/books/inbox/Roman/Krimi/k.epub --title Inboxbuch --authors 'Agatha Test' --tags Eingebettet")
        machine.wait_until_succeeds("ls /srv/books/inbox/_imported/*/Roman/Krimi/k.epub", timeout=90)
        books = json.loads(machine.succeed(f"curl -sf -b /tmp/jar '{H}/api/books?q=title:Inboxbuch'"))
        b = books["books"][0]
        assert b["tags"] == ["Krimi", "Roman"] or sorted(b["tags"]) == ["Krimi", "Roman"], b
        assert b["custom"]["kategorie"] == "Roman.Krimi", b
        # one added event, not one per write
        added = machine.succeed(f"grep -c '\"added\",{b['id']},' /var/lib/calibre-hub/events.log").strip()
        assert added == "1", added

    with subtest("failing handler is parked and alerts"):
        machine.succeed("printf 'x\\n' > /tmp/x.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/x.txt /tmp/kaputt.epub --title Kaputt --authors Niemand")
        machine.succeed(f"{DB} add /tmp/kaputt.epub")
        machine.wait_until_succeeds("grep -q '90-fail failed' /var/lib/calibre-hub/alerts.log", timeout=120)

    with subtest("deleted"):
        machine.succeed(f"{DB} remove 1")
        machine.wait_until_succeeds("grep -q '\"deleted\",1,' /var/lib/calibre-hub/events.log", timeout=30)

    with subtest("restart does not repeat events"):
        before = machine.succeed("wc -l < /var/lib/calibre-hub/events.log").strip()
        machine.systemctl("restart calibre-hub.service")
        machine.wait_for_open_port(8084)
        machine.sleep(10)
        after = machine.succeed("wc -l < /var/lib/calibre-hub/events.log").strip()
        assert before == after, (before, after)

    with subtest("opds with basic auth"):
        assert code(f"{H}/opds") == "401"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"

    with subtest("calibre-server down -> 502"):
        machine.systemctl("stop calibre-server.service")
        assert code(f"-b /tmp/jar {H}/api/books") == "502"
  '';
}
