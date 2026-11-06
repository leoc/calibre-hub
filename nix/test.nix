# NixOS VM test: calibre-server + calibre-hub from the module, an empty
# library, one book added through calibre-server. Also the smoke test against
# the calibre version of the pinned nixpkgs.
{
  pkgs,
  module,
  package,
  hub,
}:
pkgs.testers.runNixOSTest {
  name = "calibre-hub";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      imports = [ module ];
      virtualisation.memorySize = 2048;
      environment.systemPackages = [
        pkgs.calibre
        pkgs.curl
        pkgs.jq
        pkgs.sqlite
        # the CLI, as calibre-hub cli (server package) and hub (own binary)
        config.services.calibre-hub.package
        hub
      ];
      environment.etc = {
        "hub/service".text = "service-secret";
        "hub/login".text = "login-secret\n";
        "hub/key".text = "0123456789abcdef0123456789abcdef";
        "hub/scripts".text = "scripts-secret";
        "hub/token".text = "cli-token-0123456789abcdef\n";
        "hub/hardcover".text = "Bearer hardcover-test-token\n";
        "hub/lea".text = "lea-secret\n";
        "hub/lea-token".text = "lea-token-0123456789abcdef\n";
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
        apiTokenFiles = [ "/etc/hub/token" ];
        backlogImport.roots = [ "/srv/books/alt" ];
        # a second user besides the login user arthur
        users.lea = {
          role = "reader";
          passwordFile = "/etc/hub/lea";
          apiTokenFiles = [ "/etc/hub/lea-token" ];
          # her own e-reader: her synced lists go there
          leseliste.target = "/srv/books/boox-lea";
        };
        inbox = {
          path = "/srv/books/inbox";
          stableSeconds = 2;
        };
        leseliste = {
          enable = true;
          target = "/srv/books/boox";
        };
        classify = {
          enable = true;
          model = "stub";
        };
        # Hardcover, Open Library and DNB from recorded answers (sources-stub below)
        metadata = {
          enable = true;
          useModel = false;
          openLibraryUrl = "http://127.0.0.1:8095/ol";
          openLibraryCoversUrl = "http://127.0.0.1:8095/covers";
          dnbUrl = "http://127.0.0.1:8095/dnb";
          hardcoverUrl = "http://127.0.0.1:8095/hc";
          hardcoverTokenFile = "/etc/hub/hardcover";
          requestInterval = 0;
        };
        # writes only to the stub (sources-stub), never a real account
        hardcoverSync = {
          enable = true;
          write = true;
          interval = 2;
        };
        embed.delay = 2;
        convert.enable = true;
        epubFix.onImport = true;
        handlerAttempts = 2;
        alertCommand = "${pkgs.writeShellScript "alert" ''echo "$1: $2" >> /var/lib/calibre-hub/alerts.log''}";
        handlers = {
          "10-log" = pkgs.writeShellScript "log" ''${pkgs.jq}/bin/jq -c '[.type, .bookId, (.changes // {} | keys)]' >> /var/lib/calibre-hub/events.log'';
          "90-fail" = pkgs.writeShellScript "fail" ''! ${pkgs.jq}/bin/jq -e '.book.title == "Kaputt"' >/dev/null'';
        };
      };
      # a hub "update": another store path for the hub, nothing else changed
      specialisation.hub-update.configuration.services.calibre-hub.package = lib.mkForce (
        pkgs.symlinkJoin {
          name = "calibre-hub-update";
          paths = [ package ];
          meta.mainProgram = "calibre-hub";
        }
      );
      # the configuration of a single-user host (dmt): login user and tokens only
      specialisation.single-user.configuration.services.calibre-hub.users = lib.mkForce { };
      # stands in for Ollama: the part of /api/chat the hub uses, canned
      # answers by title
      systemd.services.model-stub = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "model-stub.py" ''
          import json
          from http.server import BaseHTTPRequestHandler, HTTPServer

          ANSWERS = {
              "Wüstenplanet": ("Roman/SF", 0.95, "Wüste und Raumfahrt"),
              "Mordfall": ("Roman/Krimi", 0.6, "Ein Mord im Titel"),
              "Hochgeladen": ("Roman", 0.4, "Unklar"),
          }

          class Handler(BaseHTTPRequestHandler):
              def do_POST(self):
                  body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                  if self.path != "/api/chat" or body.get("model") != "stub":
                      return self.reply(404, {"error": "model not found, try pulling it first"})
                  user = body["messages"][-1]["content"]
                  title = next(l[7:] for l in user.splitlines() if l.startswith("Title: "))
                  category, confidence, reason = ANSWERS.get(title, ("", 0, "Nichts passt"))
                  # only categories of the tree are offered
                  assert category in body["format"]["properties"]["category"]["enum"], category
                  print("asked about", title, flush=True)
                  content = json.dumps({"category": category, "confidence": confidence, "reason": reason})
                  self.reply(200, {"model": "stub", "message": {"role": "assistant", "content": content}, "done": True})

              def reply(self, status, body):
                  data = json.dumps(body).encode()
                  self.send_response(status)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(data)))
                  self.end_headers()
                  self.wfile.write(data)

          HTTPServer(("127.0.0.1", 11434), Handler).serve_forever()
        ''}";
      };
      # stands in for Hardcover, Open Library and the DNB: the recorded
      # answers of the specs (spec/fixtures/metadata) for one ISBN, nothing
      # for the rest; Hardcover only with the token from the module option
      systemd.services.sources-stub = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "sources-stub.py" ''
          import json
          import re
          from http.server import BaseHTTPRequestHandler, HTTPServer
          from urllib.parse import urlparse, parse_qs

          # the user's Hardcover library (book id -> user book) for the sync
          HC = {}
          NEXT = [1000]

          def next_id():
              NEXT[0] += 1
              return NEXT[0]

          def mutate(name, v):
              if name == "insert_user_book":
                  o = v["object"]
                  HC[o["book_id"]] = {"id": next_id(), "status_id": o["status_id"], "edition": o.get("edition_id"), "reads": []}
                  return {"id": HC[o["book_id"]]["id"], "error": None}
              ub = next((u for u in HC.values() if u["id"] == v["id"] or any(r["id"] == v["id"] for r in u["reads"])), None)
              if ub is None:
                  return {"id": None, "error": "not found"}
              if name == "delete_user_book":
                  del HC[next(b for b, u in HC.items() if u is ub)]
              elif name == "delete_user_book_read":
                  ub["reads"] = [r for r in ub["reads"] if r["id"] != v["id"]]
              elif name == "update_user_book":
                  ub.update(v["object"])
              elif name == "insert_user_book_read":
                  ub["reads"].append(dict(v["read"], id=next_id()))
              elif name == "update_user_book_read":
                  r = next(r for r in ub["reads"] if r["id"] == v["id"])
                  r.update(v["read"])
              return {"id": v["id"], "error": None}

          FIXTURES = "${../spec/fixtures/metadata}"
          EMPTY_SRU = '<searchRetrieveResponse xmlns="http://www.loc.gov/zing/srw/"><numberOfRecords>0</numberOfRecords></searchRetrieveResponse>'

          class Handler(BaseHTTPRequestHandler):
              def do_GET(self):
                  url = urlparse(self.path)
                  q = {k: v[0] for k, v in parse_qs(url.query).items()}
                  print("GET", self.path, flush=True)
                  if url.path == "/ol/api/books":
                      if q.get("bibkeys") == "ISBN:9783608938289":
                          return self.file("openlibrary_isbn.json", "application/json")
                      return self.reply("{}", "application/json")
                  if url.path == "/ol/search.json":
                      return self.reply('{"docs": []}', "application/json")
                  if url.path == "/dnb":
                      if q.get("query") == "num=9783608938289":
                          return self.file("dnb_isbn.xml", "application/xml")
                      return self.reply(EMPTY_SRU, "application/xml")
                  self.send_response(404)
                  self.end_headers()

              def do_POST(self):
                  body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                  auth = self.headers.get("Authorization")
                  print("POST", self.path, auth == "Bearer hardcover-test-token", json.dumps(body.get("variables")), flush=True)
                  if self.path != "/hc":
                      self.send_response(404)
                      self.end_headers()
                      return
                  if auth != "Bearer hardcover-test-token":
                      self.send_response(401)
                      self.end_headers()
                      return
                  q, v = body["query"], body.get("variables") or {}
                  if q.startswith("mutation"):
                      name = re.search(r"\{\s*(\w+)\(", q).group(1)
                      print("MUTATION", name, json.dumps(v, sort_keys=True), flush=True)
                      return self.reply(json.dumps({"data": {name: mutate(name, v)}}), "application/json")
                  if "user_books(" in q:
                      ids = v.get("ids")
                      books = [{"id": u["id"], "book_id": b, "status_id": u["status_id"], "edition": {"id": u["edition"], "pages": None},
                                "book": {"pages": None}, "user_book_reads": u["reads"][::-1]}
                               for b, u in HC.items() if ids is None or b in ids]
                      return self.reply(json.dumps({"data": {"me": [{"user_books": books}]}}), "application/json")
                  if v.get("isbn") == "9783608938289":
                      return self.file("hardcover_isbn_ringe.json", "application/json")
                  if "search(" in body["query"]:
                      return self.reply('{"data": {"search": {"results": {"hits": []}}}}', "application/json")
                  return self.reply('{"data": {"editions": [], "books": []}}', "application/json")

              def file(self, name, ctype):
                  with open(f"{FIXTURES}/{name}") as f:
                      self.reply(f.read(), ctype)

              def reply(self, text, ctype):
                  data = text.encode()
                  self.send_response(200)
                  self.send_header("Content-Type", ctype)
                  self.send_header("Content-Length", str(len(data)))
                  self.end_headers()
                  self.wfile.write(data)

          HTTPServer(("127.0.0.1", 8095), Handler).serve_forever()
        ''}";
      };
      systemd.tmpfiles.rules = [
        # the Eingang's trash folder goes next to the root
        "d /srv/books 2775 root calibre-hub -"
        "d /srv/books/library 2775 calibre-server calibre-hub -"
        "d /srv/books/inbox 2775 root calibre-hub -"
        "d /srv/books/boox 2775 root calibre-hub -"
        "d /srv/books/boox-lea 2775 root calibre-hub -"
        "d /srv/books/alt 0755 root root -"
      ];
    };

  testScript = ''
    import json
    import urllib.parse
    from datetime import datetime

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
    # the specialisations are below the system booted, not below a specialisation
    BASE = machine.succeed("readlink -f /run/current-system").strip()

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
        n = machine.succeed("sqlite3 -cmd '.timeout 5000' /srv/books/library/metadata.db \"select count(*) from sqlite_master where type = 'trigger' and name like 'hub_%'\"").strip()
        assert int(n) > 10, n
        machine.succeed("sqlite3 -cmd '.timeout 5000' /srv/books/library/metadata.db 'select count(*) from hub_changelog' | grep -qv '^0$'")

    with subtest("events reach handlers"):
        machine.wait_until_succeeds("grep -q '\"changed\",1,.*tags' /var/lib/calibre-hub/events.log", timeout=30)

    def api(method, path, body=None, extra=""):
        data = f"-H 'Content-Type: application/json' -d '{json.dumps(body)}'" if body is not None else ""
        out = machine.succeed(f"curl -s -b /tmp/jar -X {method} {CSRF} {data} {extra} -w '\\n%{{http_code}}' '{H}{path}'")
        text, status = out.rsplit("\n", 1)
        return int(status), (json.loads(text) if text.strip() else None)

    # the entry of a file, by its name, once the Eingang looked at it
    def entry(name, query="", seconds=900):
        for _ in range(seconds // 5):
            listed = api("GET", f"/api/intake?limit=500{query}")[1]["entries"]
            found = [e for e in listed if e["name"] == name]
            if found:
                return found[0]
            machine.sleep(5)
        raise Exception(f"{name} is not in the Eingang")

    # a decision that goes through a job, carried out
    def decide(e, decision, **extra):
        status, r = api("POST", "/api/intake/decide", {"target": {"ids": [e["id"]]}, "decision": decision, **extra})
        assert status == 202, (status, r)
        j = wait_job(r["jobId"], 180)
        assert j["status"] == "done" and j["errors"] == [], j

    # what came of an upload; below the threshold it is taken by hand
    def upload(form):
        status, r = api("POST", "/api/books", extra=form)
        assert status == 202 and r["upload"]["status"] == "checking", (status, r)
        decided = False
        for _ in range(240):
            status, s = api("GET", f"/api/intake/uploads/{r['upload']['id']}")
            assert status == 200, (status, s)
            if s["status"] == "waiting" and not decided:
                decided = True
                assert api("POST", "/api/intake/decide", {"target": {"ids": [s["entryId"]]}, "decision": "accept"})[0] == 202
            elif s["status"] not in ("checking", "waiting"):
                return s
            machine.sleep(1)
        raise Exception(f"upload {r} is still {s}")

    # a file of the inbox in the library, taken by hand when it is below the threshold
    def from_inbox(name):
        decided = False
        for _ in range(180):
            if machine.execute(f"ls /srv/books/inbox/_imported/*/{name}")[0] == 0:
                return
            found = [e for e in api("GET", "/api/intake?limit=500&origin=inbox")[1]["entries"] if e["name"] == name]
            if found and not decided:
                decided = True
                assert api("POST", "/api/intake/decide", {"target": {"ids": [found[0]["id"]]}, "decision": "accept"})[0] == 202
            machine.sleep(1)
        raise Exception(f"{name} didn't leave the inbox")

    with subtest("inbox"):
        machine.succeed("printf 'Krimi\\n\\nText\\n' > /tmp/k.txt")
        # a folder without group write is skipped, not imported twice
        machine.succeed("mkdir -m 755 /srv/books/inbox/Privat && cp /tmp/b.epub /srv/books/inbox/Privat/")
        machine.wait_until_succeeds("journalctl -u calibre-hub -o cat | grep -q 'Privat/b.epub skipped'", timeout=30)
        # like Samba on dmt: directory mask 2775
        machine.succeed("install -d -m 2775 -g calibre-hub /srv/books/inbox/Roman /srv/books/inbox/Roman/Krimi")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/k.txt /srv/books/inbox/Roman/Krimi/k.epub --title Inboxbuch --authors 'Agatha Test' --tags Eingebettet")
        # it goes through the Eingang: below the threshold it waits there, in its folder
        assert api("GET", "/api/intake?limit=1")[1]["thresholds"] == {"backlog": None, "inbox": 90, "upload": 90}
        e = entry("k.epub", "&origin=inbox", 120)
        assert e["folder"] == "Roman/Krimi" and e["confidence"] < 90, e
        machine.succeed("test -f /srv/books/inbox/Roman/Krimi/k.epub")
        assert api("GET", "/api/books?q=title:Inboxbuch")[1]["books"] == []
        # from its threshold on it goes by itself
        status, r = api("POST", "/api/intake/threshold", {"origin": "inbox", "value": 60})
        assert status == 200 and r["thresholds"]["inbox"] == 60, (status, r)
        assert api("POST", "/api/intake/threshold", {"origin": "upload", "value": 60})[0] == 200
        assert api("POST", "/api/intake/threshold", {"origin": "nowhere", "value": 60})[0] == 400
        assert api("POST", "/api/intake/threshold", {"origin": "inbox", "value": 59})[0] == 400
        machine.wait_until_succeeds("ls /srv/books/inbox/_imported/*/Roman/Krimi/k.epub", timeout=90)
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar '{H}/api/books?q=title:Inboxbuch' | jq -e '.total == 1'", timeout=30)
        books = json.loads(machine.succeed(f"curl -sf -b /tmp/jar '{H}/api/books?q=title:Inboxbuch'"))
        b = books["books"][0]
        assert b["tags"] == ["Krimi", "Roman"] or sorted(b["tags"]) == ["Krimi", "Roman"], b
        assert b["custom"]["kategorie"] == "Roman.Krimi", b
        # one added event, not one per write
        added = machine.succeed(f"grep -c '\"added\",{b['id']},' /var/lib/calibre-hub/events.log").strip()
        assert added == "1", added

    STATE = "/var/lib/calibre-hub/state.sqlite"

    with subtest("reading list tag becomes a list"):
        # migrated on the first start, when the library was still empty
        status, ls = api("GET", "/api/lists")
        assert status == 200 and [(l["name"], l["sync"], l["isDefault"], l["count"]) for l in ls] == [("Leseliste", True, True, 0)], ls
        # once more with the tagged book: as on a host that had the tag
        machine.systemctl("stop calibre-hub.service")
        machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"delete from list_items; delete from lists; delete from meta where key = 'lists_migrated'\"")
        machine.systemctl("start calibre-hub.service")
        machine.wait_for_open_port(8084)
        machine.wait_until_succeeds("test -f '/srv/books/boox/Leseliste/Lovelace, Ada - Testbuch.epub'", timeout=60)
        status, ls = api("GET", "/api/lists")
        assert [(l["name"], l["sync"], l["isDefault"], l["favorite"], l["count"]) for l in ls] == [("Leseliste", True, True, True, 1)], ls
        lid = ls[0]["id"]
        assert api("GET", "/api/books/1")[1]["lists"] == [lid]
        # the old category folders are gone, the tag no longer counts
        machine.fail("test -e /srv/books/boox/Fachbuch")
        machine.succeed(f"{DB} set_metadata 1 -f tags:")
        machine.sleep(5)
        machine.succeed("test -f '/srv/books/boox/Leseliste/Lovelace, Ada - Testbuch.epub'")

    with subtest("lists"):
        status, u = api("POST", "/api/lists", {"name": "Urlaub", "sync": True, "description": "Strand"})
        assert status == 201 and u["owner"] == "arthur" and u["visibility"] == "private", (status, u)
        assert api("POST", "/api/lists", {"name": "urlaub"})[0] == 409
        status, r = api("PUT", f"/api/lists/{u['id']}/books/1")
        assert status == 200 and r["added"] == [1] and r["list"]["count"] == 1, (status, r)
        assert api("PUT", f"/api/lists/{u['id']}/books/9999")[0] == 404
        # one folder per synced list, a book in two lists is in both
        machine.wait_until_succeeds("test -f '/srv/books/boox/Urlaub/Lovelace, Ada - Testbuch.epub'", timeout=30)
        machine.succeed("test -f '/srv/books/boox/Leseliste/Lovelace, Ada - Testbuch.epub'")
        status, page = api("GET", f"/api/books?list={u['id']}")
        assert status == 200 and page["total"] == 1 and page["books"][0]["id"] == 1, page
        assert sorted(page["books"][0]["lists"]) == sorted([lid, u["id"]]), page
        assert api("GET", f"/api/books?list={u['id']}&sort=title")[1]["total"] == 1
        assert api("GET", f"/api/books?list={u['id']}&q=title:nichts")[1]["total"] == 0
        assert api("GET", "/api/books?list=9999")[0] == 404
        assert [l["id"] for l in api("GET", "/api/books/1/lists")[1]] == sorted([lid, u["id"]])
        # renaming moves the folder
        status, u = api("PATCH", f"/api/lists/{u['id']}", {"name": "Sommer"})
        assert status == 200 and u["name"] == "Sommer", (status, u)
        machine.wait_until_succeeds("test -f '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.epub'", timeout=30)
        machine.succeed("test ! -e /srv/books/boox/Urlaub")
        # removing a book removes its file, not what the e-reader keeps next to it
        machine.succeed("mkdir '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.sdr' && echo x > '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.sdr/metadata.epub.lua'")
        status, r = api("DELETE", f"/api/lists/{u['id']}/books/1")
        assert status == 200 and r["removed"] == [1] and r["list"]["count"] == 0, (status, r)
        machine.wait_until_succeeds("! test -e '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.epub'", timeout=30)
        machine.succeed("test -f '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.sdr/metadata.epub.lua'")
        machine.succeed("rm -r '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.sdr'")
        machine.succeed("test -f '/srv/books/boox/Leseliste/Lovelace, Ada - Testbuch.epub'")
        status, r = api("POST", f"/api/lists/{u['id']}/books", {"target": {"query": {"q": "title:Testbuch"}}})
        assert status == 200 and r["added"] == [1], (status, r)
        machine.wait_until_succeeds("test -f '/srv/books/boox/Sommer/Lovelace, Ada - Testbuch.epub'", timeout=30)
        assert api("DELETE", f"/api/lists/{u['id']}")[0] == 200
        machine.wait_until_succeeds("! test -e /srv/books/boox/Sommer", timeout=30)
        machine.wait_until_succeeds("grep -q '\"list\",0,' /var/lib/calibre-hub/events.log", timeout=30)
        # nested lists: a synced parent takes its sublists along, in nested folders
        status, sub = api("POST", "/api/lists", {"name": "Reise / 2026"})
        assert status == 201 and sub["name"] == "Reise/2026" and sub["parent"] == "Reise", (status, sub)
        assert api("POST", "/api/lists", {"name": "Reise//x"})[0] == 400
        assert api("PUT", f"/api/lists/{sub['id']}/books/1")[0] == 200
        status, page = api("GET", "/api/books?listPath=Reise")
        assert status == 200 and page["total"] == 1, (status, page)
        assert api("GET", "/api/books?listPath=Reise&direct=1")[1]["total"] == 0
        status, parent = api("POST", "/api/lists", {"name": "Reise", "sync": True})
        assert status == 201 and parent["totalCount"] == 1 and parent["count"] == 0, (status, parent)
        assert api("GET", f"/api/books?list={parent['id']}")[1]["total"] == 1
        machine.wait_until_succeeds("test -f '/srv/books/boox/Reise/2026/Lovelace, Ada - Testbuch.epub'", timeout=30)
        # renaming the parent renames the sublist and moves the folders
        status, parent = api("PATCH", f"/api/lists/{parent['id']}", {"name": "Fahrt"})
        assert status == 200 and api("GET", f"/api/lists/{sub['id']}")[1]["name"] == "Fahrt/2026"
        machine.wait_until_succeeds("test -f '/srv/books/boox/Fahrt/2026/Lovelace, Ada - Testbuch.epub'", timeout=30)
        machine.wait_until_succeeds("test ! -e /srv/books/boox/Reise", timeout=30)
        # deleting the parent leaves the sublist, no longer synced
        assert api("DELETE", f"/api/lists/{parent['id']}")[0] == 200
        assert api("GET", f"/api/lists/{sub['id']}")[0] == 200
        machine.wait_until_succeeds("! test -e /srv/books/boox/Fahrt", timeout=30)
        assert api("GET", "/api/books?listPath=Fahrt")[1]["total"] == 1
        assert api("DELETE", f"/api/lists/{sub['id']}")[0] == 200
        # each list is an OPDS catalog, with Basic auth like /opds
        assert code(f"{H}/opds/lists/{lid}") == "401"
        nav = machine.succeed(f"curl -sf -u arthur:login-secret {H}/opds/lists")
        assert f"/opds/lists/{lid}" in nav and "<title>Leseliste</title>" in nav, nav
        feed = machine.succeed(f"curl -sf -u arthur:login-secret -D /tmp/opds-headers {H}/opds/lists/{lid}")
        machine.succeed("grep -qi 'content-type: application/atom+xml;profile=opds-catalog;kind=acquisition' /tmp/opds-headers")
        assert "<title>Testbuch</title>" in feed and 'rel="http://opds-spec.org/acquisition"' in feed, feed
        href = feed.split('rel="http://opds-spec.org/acquisition" href="')[1].split('"')[0]
        assert href.startswith("/get/epub/1"), href
        assert code(f"-u arthur:login-secret '{H}{href}'") == "200"
        assert code(f"-u arthur:login-secret {H}/opds/lists/9999") == "404"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"
        CLI = "CALIBRE_HUB_URL=http://127.0.0.1:8084 CALIBRE_HUB_TOKEN_FILE=/etc/hub/token"
        ls = json.loads(machine.succeed(f"{CLI} hub list ls --json"))
        assert [l["name"] for l in ls] == ["Leseliste"], ls
        machine.succeed(f"{CLI} hub list create Krimis --sync")
        machine.succeed(f"{CLI} hub list add krimis 1")
        machine.wait_until_succeeds("test -f '/srv/books/boox/Krimis/Lovelace, Ada - Testbuch.epub'", timeout=30)
        shown = json.loads(machine.succeed(f"{CLI} hub list show Krimis --json"))
        assert shown["books"]["total"] == 1 and shown["list"]["sync"] is True, shown
        machine.succeed(f"{CLI} hub list create Krimis/Klassiker")
        tree = machine.succeed(f"{CLI} hub list ls --tree")
        assert "Klassiker" in tree and "Krimis" in tree, tree
        shown = json.loads(machine.succeed(f"{CLI} hub list show Krimis/Klassiker --json"))
        assert shown["list"]["name"] == "Krimis/Klassiker" and shown["books"]["total"] == 0, shown
        assert json.loads(machine.succeed(f"{CLI} hub list show Krimis --json"))["books"]["total"] == 1
        machine.succeed(f"{CLI} hub list delete Krimis/Klassiker --yes")
        machine.succeed(f"{CLI} hub list delete Krimis --yes")
        machine.wait_until_succeeds("! test -e /srv/books/boox/Krimis", timeout=30)
        status, r = api("DELETE", f"/api/lists/{lid}/books/1")
        machine.wait_until_succeeds("! find /srv/books/boox -name '*.epub' | grep -q .", timeout=30)

    with subtest("magic shelves"):
        inbox = api("GET", "/api/books?q=title:Inboxbuch")[1]["books"][0]["id"]
        # OR: the Roman category (incl. Roman.Krimi) or Ada Lovelace's book
        rule = {"match": "any", "conditions": [{"field": "kategorie", "value": "Roman"}, {"field": "author", "value": "Ada Lovelace"}]}
        status, s = api("POST", "/api/lists", {"name": "Regal", "favorite": True, "rule": rule})
        assert status == 201 and s["count"] == 2 and s["rule"]["match"] == "any" and s["queryError"] is None, (status, s)
        status, page = api("GET", f"/api/books?list={s['id']}&sort=title")
        assert status == 200 and page["total"] == 2, (status, page)
        # AND with a negated condition
        rule = {"match": "all", "conditions": [{"field": "kategorie", "value": "Roman"}, {"field": "author", "value": "Ada Lovelace", "not": True}]}
        status, s = api("PATCH", f"/api/lists/{s['id']}", {"rule": rule})
        assert status == 200 and s["count"] == 1 and s["coverBookIds"] == [inbox], (status, s)
        assert [b["id"] for b in api("GET", f"/api/books?list={s['id']}")[1]["books"]] == [inbox]
        # calibre rejects the search: 400, nothing stored
        status, r = api("POST", "/api/lists", {"name": "Kaputt", "rule": {"conditions": [{"field": "text", "value": "(title:x"}]}})
        assert status == 400 and r["field"] == "rule", (status, r)
        assert api("PUT", f"/api/lists/{s['id']}/books/1")[0] == 400
        assert api("PATCH", f"/api/lists/{s['id']}", {"sync": True})[0] == 400
        feed = machine.succeed(f"curl -sf -u arthur:login-secret {H}/opds/lists/{s['id']}")
        assert "<title>Inboxbuch</title>" in feed, feed
        assert api("DELETE", f"/api/lists/{s['id']}")[0] == 200

    with subtest("edit"):
        assert code(f"-b /tmp/jar -X PATCH -d '{{}}' {H}/api/books/1") == "403"
        n = int(machine.succeed("grep -c '\"changed\",1,' /var/lib/calibre-hub/events.log").strip())
        status, b = api("PATCH", "/api/books/1", {"addTags": ["neu"]})
        assert status == 200 and "neu" in b["tags"], (status, b)
        machine.wait_until_succeeds(f"test $(grep -c '\"changed\",1,' /var/lib/calibre-hub/events.log) -gt {n}", timeout=30)
        status, b2 = api("PATCH", "/api/books/1", {"title": "Neuer Titel", "series": "Reihe", "seriesIndex": 3,
            "rating": 8, "pubdate": "2020-05-01", "kategorie": "Roman", "identifiers": {"isbn": "9780000000001"},
            "comments": "<p onclick=x>Hallo<script>alert(1)</script></p>", "lastModified": b["lastModified"]})
        assert status == 200, (status, b2)
        assert b2["title"] == "Neuer Titel" and b2["series"] == "Reihe" and b2["seriesIndex"] == 3 and b2["rating"] == 8, b2
        assert b2["pubdate"].startswith("2020-05-") and b2["custom"]["kategorie"] == "Roman", b2
        assert b2["identifiers"] == {"isbn": "9780000000001"} and b2["comments"] == "<p>Hallo</p>", b2
        assert b2["lastModified"] != b["lastModified"], b2
        status, c = api("PATCH", "/api/books/1", {"title": "Alt", "lastModified": b["lastModified"]})
        assert status == 409 and c["book"]["title"] == "Neuer Titel", (status, c)
        status, c = api("PATCH", "/api/books/1", {"series": None, "rating": None, "pubdate": None, "kategorie": None})
        assert status == 200 and c["series"] is None and c["seriesIndex"] is None and c["rating"] is None, c
        assert c["custom"]["kategorie"] is None and c["pubdate"] is None, c
        status, c = api("PATCH", "/api/books/1", {"rating": 11})
        assert status == 400 and c["field"] == "rating", (status, c)
        assert api("PATCH", "/api/books/999", {"title": "x"})[0] == 404

    with subtest("upload"):
        machine.succeed("printf 'Upload\\n\\nText\\n' > /tmp/u.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/u.txt /tmp/Upload.epub --title Hochgeladen --authors 'Ulla Upload' --tags Eingebettet")
        form = "-F file=@/tmp/Upload.epub -F tags=Roman -F tags=Neu -F kategorie=Roman.Krimi"
        # a new book goes through the Eingang; the form's tags and category come along
        r = upload(form)
        assert r["status"] == "imported" and sorted(r["book"]["tags"]) == ["Neu", "Roman"] and r["book"]["custom"]["kategorie"] == "Roman.Krimi", r
        uid = r["book"]["id"]
        machine.wait_until_succeeds(f"grep -q '\"added\",{uid},' /var/lib/calibre-hub/events.log", timeout=30)
        machine.succeed("ls /var/lib/calibre-hub/uploads/_imported/*/*/Upload.epub")
        # the same file again: it says so, nothing is added
        r = upload("-F file=@/tmp/Upload.epub")
        assert r["status"] in ("copy", "duplicate") and r["duplicates"][0]["id"] == uid, r
        if r["status"] == "duplicate":
            assert api("POST", "/api/intake/decide", {"target": {"ids": [r["entryId"]]}, "decision": "trash"})[0] == 202
        r = upload("-F file=@/tmp/Upload.epub -F force=1")
        assert r["status"] == "imported" and r["book"]["id"] != uid, r
        status, r = api("POST", "/api/books", extra=f"-F file=@/tmp/u.txt -F addFormatTo={uid}")
        assert status == 200 and "TXT" in r["book"]["formats"], (status, r)
        machine.succeed("echo x > /tmp/evil.exe")
        assert api("POST", "/api/books", extra="-F file=@/tmp/evil.exe")[0] == 415

    def wait_job(job_id, seconds=60):
        for _ in range(seconds):
            status, j = api("GET", f"/api/jobs/{job_id}")
            assert status == 200, (status, j)
            if j["status"] != "running":
                return j
            machine.sleep(1)
        raise Exception("job still running")

    with subtest("bulk"):
        status, r = api("POST", "/api/books/bulk", {"target": {"ids": [1, uid, 999]}, "changes": {"addTags": ["Stapel"], "series": "Serie"}})
        assert status == 202 and r["total"] == 3, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["done"] == 3 and [e["bookId"] for e in j["errors"]] == [999], j
        assert "Stapel" in api("GET", f"/api/books/{uid}")[1]["tags"]
        status, r = api("POST", "/api/books/bulk", {"target": {"query": {"tag": "Stapel"}}, "changes": {"removeTags": ["stapel"], "kategorie": "Bulk"}})
        assert status == 202 and r["total"] == 2, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        b = api("GET", "/api/books/1")[1]
        assert "Stapel" not in b["tags"] and b["custom"]["kategorie"] == "Bulk" and b["series"] == "Serie", b
        assert api("POST", "/api/books/bulk", {"target": {"ids": [1]}, "changes": {"title": "x"}})[0] == 400
        # an empty or mistyped filter is no "every book", least of all to delete
        for target in [{"query": {}}, {"query": {"tags": "Stapel"}}, {"query": {"q": " "}}]:
            status, e = api("POST", "/api/books/bulk", {"target": target, "changes": {"delete": True}})
            assert status == 400 and e["field"] == "target", (target, status, e)
        status, e = api("POST", "/api/books/bulk", {"target": {"query": {"tag": "Bulk"}}, "changes": {"delete": True}})
        assert status == 400 and e["field"] == "target", (status, e)
        status, e = api("POST", "/api/books/bulk", {"target": {"query": {"kategorie": "Bulk"}, "expect": 99}, "changes": {"delete": True}})
        assert status == 409 and e["found"] == 2, (status, e)
        # an undo leaves what changed after the job
        publisher = api("GET", "/api/books/1")[1]["publisher"]
        status, r = api("POST", "/api/books/bulk", {"target": {"ids": [1]}, "changes": {"addTags": ["Rückgängig"], "publisher": "Bulkverlag"}})
        assert wait_job(r["jobId"])["status"] == "done"
        assert api("PATCH", "/api/books/1", {"addTags": ["Hand"], "publisher": "Handverlag"})[0] == 200
        status, r = api("POST", f"/api/jobs/{r['jobId']}/undo")
        assert status == 202, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [{"bookId": 1, "error": "changed since, left as it is: publisher"}], j
        b = api("GET", "/api/books/1")[1]
        assert "Hand" in b["tags"] and "Rückgängig" not in b["tags"] and b["publisher"] == "Handverlag", b
        assert api("PATCH", "/api/books/1", {"removeTags": ["Hand"], "publisher": publisher})[0] == 200
        assert api("GET", "/api/jobs/unknown")[0] == 404
        # series numbered in the order of the ids
        status, r = api("POST", "/api/books/bulk", {"target": {"ids": [uid, 1]}, "changes": {"series": "Nummern", "numberSeries": True}})
        assert status == 202 and r["total"] == 2, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        b = api("GET", f"/api/books/{uid}")[1]
        assert b["series"] == "Nummern" and b["seriesIndex"] == 1, b
        b = api("GET", "/api/books/1")[1]
        assert b["series"] == "Nummern" and b["seriesIndex"] == 2, b
        status, e = api("POST", "/api/books/bulk", {"target": {"query": {"tag": "Roman"}}, "changes": {"series": "S", "numberSeries": True}})
        assert status == 400 and e["field"] == "numberSeries", (status, e)
        status, e = api("POST", "/api/books/bulk", {"target": {"ids": [1]}, "changes": {"numberSeries": True}})
        assert status == 400 and e["field"] == "numberSeries", (status, e)

    with subtest("bulk job survives a hub restart"):
        # mostly unknown ids, so the job runs long enough to be cut off
        ids = list(range(1000, 2500)) + [uid]
        status, r = api("POST", "/api/books/bulk", {"target": {"ids": ids}, "changes": {"addTags": ["Neustart"]}})
        assert status == 202 and r["total"] == len(ids), (status, r)
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/jobs/{r['jobId']} | jq -e '.done > 0'", timeout=30)
        machine.systemctl("restart calibre-hub.service")
        machine.wait_for_open_port(8084)
        # the worker picks the job up shortly after the port is open
        machine.wait_until_succeeds(f"journalctl -u calibre-hub -o cat | grep -q 'resuming job {r['jobId']} at '", timeout=30)
        j = wait_job(r["jobId"], 180)
        assert j["status"] == "done" and j["done"] == len(ids), {k: v for k, v in j.items() if k != "errors"}
        assert len(j["errors"]) == len(ids) - 1 and uid not in [e["bookId"] for e in j["errors"]], len(j["errors"])
        assert "Neustart" in api("GET", f"/api/books/{uid}")[1]["tags"]

    with subtest("cover"):
        machine.succeed(f"curl -sf -b /tmp/jar -o /tmp/c.jpg {H}/api/books/{uid}/cover")
        before = api("GET", "/api/books/1")[1]["lastModified"]
        status, b = api("PUT", "/api/books/1/cover", extra="-H 'Content-Type: image/jpeg' --data-binary @/tmp/c.jpg")
        assert status == 200 and b["lastModified"] != before, (status, b)
        machine.succeed("printf 'RIFF\\0\\0\\0\\0WEBPVP8 ' > /tmp/c.webp")
        assert api("PUT", "/api/books/1/cover", extra="--data-binary @/tmp/c.webp")[0] == 415
        assert api("PUT", "/api/books/1/cover", extra="--data-binary @/tmp/u.txt")[0] == 415
        before = b["lastModified"]
        status, b = api("POST", f"/api/books/{uid}/cover/from-file", {})
        assert status == 200 and b["id"] == uid, (status, b)
        status, b = api("POST", "/api/books/1/cover/from-file", {"format": "pdf"})
        assert status == 400 and b["field"] == "format", (status, b)
        status, b = api("POST", "/api/books/1/cover/from-url", {"url": "http://127.0.0.1:8083/get/cover/1"})
        assert status == 400 and b["field"] == "url" and "not allowed" in b["error"], (status, b)
        status, hits = api("GET", "/api/books/1/cover/search")
        assert status == 200 and isinstance(hits, list), (status, hits)

    with subtest("api token and cli"):
        TOK = "-H 'Authorization: Bearer cli-token-0123456789abcdef'"
        assert code(f"{TOK} {H}/api/books") == "200"
        assert code(f"-H 'Authorization: Bearer wrong-token-0123456789' {H}/api/books") == "401"
        # no CSRF header needed with a token alone, again once a cookie comes along
        assert code(f"{TOK} -X PATCH -H 'Content-Type: application/json' -d '{{}}' {H}/api/books/{uid}") == "200"
        assert code(f"{TOK} -b /tmp/jar -X PATCH -d '{{}}' {H}/api/books/{uid}") == "403"
        CLI = "CALIBRE_HUB_URL=http://127.0.0.1:8084 CALIBRE_HUB_TOKEN_FILE=/etc/hub/token"
        r = json.loads(machine.succeed(f"{CLI} calibre-hub cli search --json title:Hochgeladen"))
        assert r["total"] >= 1 and all(b["title"] == "Hochgeladen" for b in r["books"]), r
        machine.succeed(f"{CLI} hub tag add {uid} cli-tag")
        assert "cli-tag" in api("GET", f"/api/books/{uid}")[1]["tags"]
        j = json.loads(machine.succeed(f"{CLI} hub bulk --ids 1,{uid} --series CLI --number-series --yes --json"))
        assert j["status"] == "done" and j["errors"] == [], j
        b = api("GET", f"/api/books/{uid}")[1]
        assert b["series"] == "CLI" and b["seriesIndex"] == 2, b
        assert machine.execute(f"{CLI} hub show 99999")[0] == 2
        assert machine.execute("CALIBRE_HUB_URL=http://127.0.0.1:8084 CALIBRE_HUB_TOKEN=wrong-token-0123456789 hub search")[0] == 4

    with subtest("delete, trash, restore"):
        # calibre's own expiry is off (init.sh)
        pref = machine.succeed("sqlite3 -cmd '.timeout 5000' /srv/books/library/metadata.db \"select val from preferences where key = 'expire_old_trash_after'\"").strip()
        assert int(pref) >= 100 * 365 * 86400, pref
        b = api("GET", f"/api/books/{uid}")[1]
        status, r = api("PUT", f"/api/lists/{lid}/books/{uid}")
        assert status == 200, (status, r)
        mirrored = "find /srv/books/boox/Leseliste -name '*Hochgeladen.epub' | grep -q ."
        machine.wait_until_succeeds(mirrored, timeout=30)
        assert code(f"-b /tmp/jar -X DELETE {H}/api/books/{uid}") == "403"
        status, r = api("DELETE", f"/api/books/{uid}")
        assert status == 200 and r["book"]["id"] == uid and r["book"]["title"] == "Hochgeladen", (status, r)
        assert api("GET", f"/api/books/{uid}")[0] == 404
        assert api("DELETE", f"/api/books/{uid}")[0] == 404
        machine.wait_until_succeeds(f"grep -q '\"deleted\",{uid},' /var/lib/calibre-hub/events.log", timeout=30)
        machine.wait_until_succeeds(f"! {mirrored}", timeout=30)
        # the deleted book left its list
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/lists/{lid} | jq -e '.count == 0'", timeout=30)
        machine.succeed(f"test -f /srv/books/library/.caltrash/b/{uid}/metadata.opf")
        status, trash = api("GET", "/api/trash")
        entry = next(e for e in trash if e["id"] == uid)
        assert entry["title"] == "Hochgeladen" and entry["authors"] == ["Ulla Upload"], entry
        assert sorted(entry["formats"]) == ["EPUB", "TXT"] and entry["deletedAt"], entry
        status, r = api("POST", f"/api/trash/{uid}/restore")
        assert status == 200, (status, r)
        rb = r["book"]
        assert rb["title"] == "Hochgeladen" and rb["authors"] == ["Ulla Upload"], rb
        assert sorted(rb["formats"]) == ["EPUB", "TXT"], rb
        assert rb["custom"]["kategorie"] == b["custom"]["kategorie"] and rb["series"] == b["series"], (rb, b)
        added = lambda x: datetime.fromisoformat(x["added"]).replace(microsecond=0)
        assert added(rb) == added(b), (rb, b)
        rid = rb["id"]
        assert code(f"-b /tmp/jar '{H}/api/books/{rid}/cover'") == "200"
        machine.wait_until_succeeds(f"grep -q '\"added\",{rid},' /var/lib/calibre-hub/events.log", timeout=30)
        # back in the list it was in, with its new id
        assert api("GET", f"/api/books/{rid}")[1]["lists"] == [lid]
        machine.wait_until_succeeds(mirrored, timeout=30)
        assert all(e["id"] != uid for e in api("GET", "/api/trash")[1])
        assert api("POST", f"/api/trash/{uid}/restore")[0] == 404
        # bulk delete moves to the trash too
        status, r = api("POST", "/api/books/bulk", {"target": {"ids": [rid]}, "changes": {"delete": True}})
        assert status == 202, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        assert api("GET", f"/api/books/{rid}")[0] == 404
        assert any(e["id"] == rid for e in api("GET", "/api/trash")[1])
        machine.wait_until_succeeds(f"! {mirrored}", timeout=30)

    with subtest("duplicates: detect, merge, undo"):
        machine.succeed("printf 'Doppelt\\n\\nText\\n' > /tmp/d.txt")
        for fmt in ("epub", "azw3"):
            machine.succeed(f"QT_QPA_PLATFORM=offscreen ebook-convert /tmp/d.txt /tmp/Doppelbuch.{fmt} --title Doppelbuch --authors 'Dora Doppel'")
        r = upload("-F file=@/tmp/Doppelbuch.epub")
        assert r["status"] == "imported", r
        keep = r["book"]["id"]
        # the Eingang asks about the copy; forced, the hub's detection names the first
        r = upload("-F file=@/tmp/Doppelbuch.azw3 -F tags=Zweitkopie")
        assert r["status"] == "duplicate" and [b["id"] for b in r["duplicates"]] == [keep], r
        decide({"id": r["entryId"]}, "trash")
        r = upload("-F file=@/tmp/Doppelbuch.azw3 -F tags=Zweitkopie -F force=1")
        assert r["status"] == "imported" and [b["id"] for b in r["possibleDuplicates"]] == [keep], r
        other = r["book"]["id"]
        # the copy is converted to EPUB too (convert.enable); wait for it, so nothing changes under the merge
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{other} | jq -e '.formats | sort == [\"AZW3\", \"EPUB\"]'", timeout=120)
        status, dl = api("POST", "/api/lists", {"name": "Doppelt"})
        assert status == 201, (status, dl)
        assert api("PUT", f"/api/lists/{dl['id']}/books/{other}")[0] == 200
        assert api("PUT", f"/api/books/{other}/progress", {"format": "azw3", "position": "epubcfi(/6/2)", "fraction": 0.3, "device": "boox"})[0] == 200

        status, d = api("GET", "/api/duplicates")
        assert status == 200 and d["threshold"] == 0.85, (status, d)
        g = next(g for g in d["groups"] if keep in g["bookIds"])
        assert g["bookIds"] == sorted([keep, other]) and g["sure"], g
        assert any(x["kind"] == "title" for x in g["reasons"]), g
        # the file sizes come from metadata.db
        assert all(b["files"] and not any(f["tiny"] for f in b["files"]) for b in g["books"]), g

        status, p = api("POST", "/api/duplicates/merge", {"keepId": keep, "bookIds": [other], "dryRun": True})
        assert status == 200 and p["plan"]["formats"] == [{"format": "AZW3", "from": other, "replace": False}], (status, p)
        assert p["plan"]["lists"] == 1 and p["plan"]["progress"] == 1 and p["plan"]["trash"] == [other], p
        assert api("GET", f"/api/books/{other}")[0] == 200

        # the metadata cleanup or the classifier may write the book right then (409; nothing merged yet)
        for _ in range(5):
            status, m = api("POST", "/api/duplicates/merge", {"keepId": keep, "bookIds": [other]})
            if status != 409:
                break
            machine.sleep(2)
        assert status == 200 and m["merge"]["status"] == "done", (status, m)
        b = m["book"]
        assert sorted(b["formats"]) == ["AZW3", "EPUB"] and "Zweitkopie" in b["tags"], b
        assert api("GET", f"/api/books/{other}")[0] == 404
        assert any(e["id"] == other for e in api("GET", "/api/trash")[1])
        machine.succeed(f"test -f /srv/books/library/.caltrash/b/{other}/metadata.opf")
        assert api("GET", f"/api/books/{keep}")[1]["lists"] == [dl["id"]]
        assert api("GET", f"/api/books/{keep}/progress")[1]["latest"]["position"] == "epubcfi(/6/2)"
        assert all(keep not in g["bookIds"] for g in api("GET", "/api/duplicates")[1]["groups"])

        status, u = api("POST", f"/api/duplicates/merges/{m['merge']['id']}/undo")
        assert status == 200 and u["merge"]["status"] == "undone", (status, u)
        back = u["merge"]["restored"][str(other)]
        assert back not in (keep, other), u
        assert api("GET", f"/api/books/{keep}")[1]["formats"] == ["EPUB"]
        assert "Zweitkopie" not in api("GET", f"/api/books/{keep}")[1]["tags"]
        rb = api("GET", f"/api/books/{back}")[1]
        assert sorted(rb["formats"]) == ["AZW3", "EPUB"] and "Zweitkopie" in rb["tags"], rb
        assert all(e["id"] != other for e in api("GET", "/api/trash")[1])
        assert api("GET", f"/api/books/{keep}")[1]["lists"] == []
        assert rb["lists"] == [dl["id"]], rb
        assert api("GET", f"/api/books/{back}/progress")[1]["latest"]["position"] == "epubcfi(/6/2)"
        assert api("GET", f"/api/books/{keep}/progress")[1]["latest"] is None
        assert api("POST", f"/api/duplicates/merges/{m['merge']['id']}/undo")[0] == 409
        # no duplicates: the pair stays out until taken back
        status, r = api("POST", "/api/duplicates/ignore", {"bookIds": [keep, back]})
        assert status == 200 and r["ignored"] == 1, (status, r)
        assert all(keep not in g["bookIds"] for g in api("GET", "/api/duplicates")[1]["groups"])

    def book_by_title(title):
        q = urllib.parse.quote(f'title:"={title}"')
        books = json.loads(machine.succeed(f"curl -sf -b /tmp/jar '{H}/api/books?q={q}'"))["books"]
        assert len(books) == 1, books
        return books[0]

    def epub(title):
        machine.succeed(f"printf '{title}\\n\\nText\\n' > /tmp/{title}.txt")
        machine.succeed(f"QT_QPA_PLATFORM=offscreen ebook-convert /tmp/{title}.txt /tmp/{title}.epub --title {title} --authors 'Klara Klassisch'")
        return f"/tmp/{title}.epub"

    def add_book(title):
        machine.succeed(f"{DB} add {epub(title)}")
        return book_by_title(title)["id"]

    with subtest("classify"):
        cfg = api("GET", "/api/config")[1]
        assert cfg["classify"] is True, cfg
        status, st = api("GET", "/api/classify/status")
        assert status == 200 and st["enabled"] and st["model"] == "stub" and st["threshold"] == 0.85, st
        # the tree so far: Bulk, Roman, Roman.Krimi; Roman.SF from a book of
        # its own, added with its category, so it isn't classified
        r = upload(f"-F file=@{epub('Fern')} -F kategorie=Roman.SF")
        assert r["status"] == "imported", r
        machine.wait_for_unit("model-stub.service")
        # the upload without a category in "upload" was classified on its added event
        dup = book_by_title("Hochgeladen")["id"]
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/suggestions/{dup} | jq -e '.status == \"pending\"'", timeout=60)

        # model down: the run stops as failed, nothing else breaks
        machine.systemctl("stop model-stub.service")
        mord = add_book("Mordfall")
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/classify/status | jq -e '.lastRun.status == \"failed\" and (.lastRun.error | contains(\"model unavailable\"))'", timeout=90)
        assert api("GET", f"/api/suggestions/{mord}")[0] == 404
        assert code(f"-b /tmp/jar {H}/api/books") == "200"
        machine.systemctl("start model-stub.service")
        machine.wait_for_open_port(11434)

        # a new book without a category is classified through its added event,
        # sure enough to be applied with the tag
        dune = add_book("Wüstenplanet")
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{dune} | jq -e '.custom.kategorie == \"Roman.SF\"'", timeout=90)
        b = api("GET", f"/api/books/{dune}")[1]
        assert "auto-kategorie" in b["tags"], b
        s = api("GET", f"/api/suggestions/{dune}")[1]
        assert s["status"] == "auto" and s["category"] == "Roman.SF" and s["confidence"] == 0.95 and s["model"] == "stub", s

        # run over the unsorted books: the rest waits for review
        status, r = api("POST", "/api/classify", {"target": "unsorted"})
        assert status == 202 and r["total"] >= 1, (status, r)
        j = wait_job(r["jobId"], 120)
        assert j["status"] == "done" and j["errors"] == [], j
        status, pending = api("GET", "/api/suggestions?status=pending")
        assert status == 200, (status, pending)
        by_id = {p["bookId"]: p for p in pending}
        assert by_id[mord]["category"] == "Roman.Krimi" and by_id[mord]["confidence"] == 0.6, pending
        assert by_id[mord]["reason"] == "Ein Mord im Titel" and by_id[mord]["book"]["title"] == "Mordfall", pending
        assert dune not in by_id, pending
        assert api("GET", "/api/books/" + str(mord))[1]["custom"]["kategorie"] is None
        st = api("GET", "/api/classify/status")[1]
        assert st["pending"] == len(pending) and st["lastRun"]["id"] == r["jobId"], st
        # nothing new to ask for the same tree
        assert api("POST", "/api/classify", {"target": "unsorted"})[1]["total"] == 0

        # accept and reject
        assert code(f"-b /tmp/jar -X POST {H}/api/suggestions/{mord}/accept") == "403"
        status, s = api("POST", f"/api/suggestions/{mord}/accept", {})
        assert status == 200 and s["status"] == "applied", (status, s)
        b = api("GET", f"/api/books/{mord}")[1]
        assert b["custom"]["kategorie"] == "Roman.Krimi" and "auto-kategorie" not in b["tags"], b
        assert by_id[dup]["category"] == "Roman" and by_id[dup]["confidence"] == 0.4, pending
        other = dup
        status, s = api("POST", f"/api/suggestions/{other}/reject")
        assert status == 200 and s["status"] == "rejected", (status, s)
        assert api("GET", f"/api/books/{other}")[1]["custom"]["kategorie"] is None
        assert api("GET", "/api/suggestions?status=pending")[1] == []
        status, r = api("POST", "/api/suggestions/accept", {"bookIds": [other, 99999]})
        assert status == 200 and [e["bookId"] for e in r["errors"]] == [99999], r
        assert api("GET", f"/api/books/{other}")[1]["custom"]["kategorie"] == "Roman", r

    with subtest("metadata"):
        assert api("GET", "/api/config")[1]["metadata"] is True
        status, st = api("GET", "/api/metadata/status")
        assert status == 200 and st["enabled"] and st["sources"] == ["file", "hardcover", "dnb", "openlibrary"], st
        machine.wait_for_open_port(8095)
        # a German book named from its file, with the ISBN only on its first page
        machine.succeed("printf 'Der Herr der Ringe\\n\\nISBN 978-3-608-93828-9\\n\\nText\\n' > /tmp/ringe.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/ringe.txt /tmp/ringe.epub --title 'tolkien - der herr der ringe (z-lib.org)' --authors Unbekannt --language de")
        machine.succeed(f"{DB} add /tmp/ringe.epub")
        messy = book_by_title("tolkien - der herr der ringe (z-lib.org)")["id"]
        # the added event starts a run: cleaned by the rules, completed by
        # the ISBN from the text through the stubbed sources
        # the rules write first, the catalogs after them, and the log last
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{messy} | jq -e '.title == \"Der Herr der Ringe\" and .publisher != null and .comments != null'", timeout=90)
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar '{H}/api/metadata/changes?bookId={messy}' | jq -e '[.changes[].field] | contains([\"title\", \"authors\", \"isbn\", \"publisher\", \"comments\"])'", timeout=30)
        b = api("GET", f"/api/books/{messy}")[1]
        assert b["authors"] == ["J.R.R. Tolkien"], b
        assert b["identifiers"].get("isbn") == "9783608938289", b
        # calibre may keep the date a day off (time zones)
        # publisher from the DNB (edition sources first), the full date
        # from Open Library, the description from Hardcover
        assert b["publisher"] == "Klett-Cotta" and b["pubdate"].startswith("2009-08-0"), b
        assert b["comments"].startswith("<p>Die Gefährten"), b
        assert "auto-metadaten" in b["tags"], b
        status, log = api("GET", f"/api/metadata/changes?bookId={messy}")
        assert status == 200, (status, log)
        by_field = {c["field"]: c for c in log["changes"]}
        assert by_field["title"]["old"] == "tolkien - der herr der ringe (z-lib.org)" and by_field["title"]["source"] == "rules", by_field
        assert by_field["authors"]["old"] == ["Unbekannt"] and by_field["isbn"]["source"] == "hardcover", by_field
        # the token came through the module option (a systemd credential)
        assert by_field["comments"]["source"] == "hardcover", by_field
        machine.fail("grep -q Hardcover /var/lib/calibre-hub/alerts.log")
        assert log["books"][0]["id"] == messy, log
        # classified after the cleanup, on the clean title
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/suggestions/{messy} | jq -e '.status == \"none\"'", timeout=60)
        machine.succeed("journalctl -u model-stub -o cat | grep -q 'asked about Der Herr der Ringe'")
        machine.fail("journalctl -u model-stub -o cat | grep -q 'asked about tolkien'")

        # a run over chosen books; nothing new for this one
        status, r = api("POST", "/api/metadata/run", {"target": {"ids": [messy]}})
        assert status == 202 and r["total"] == 1, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        assert api("GET", "/api/metadata/status")[1]["lastRun"]["id"] == r["jobId"]
        assert len(api("GET", f"/api/metadata/changes?bookId={messy}")[1]["changes"]) == len(log["changes"])

        # revert one change, then the rest of the book
        status, r = api("POST", f"/api/metadata/changes/{by_field['publisher']['id']}/revert")
        assert status == 200 and r["book"]["publisher"] is None, (status, r)
        status, r = api("POST", "/api/metadata/changes/revert", {"bookIds": [messy]})
        assert status == 200 and r["errors"] == [], (status, r)
        b = api("GET", f"/api/books/{messy}")[1]
        assert b["title"] == "tolkien - der herr der ringe (z-lib.org)" and b["authors"] == ["Unbekannt"], b
        assert "isbn" not in b["identifiers"] and not (b["pubdate"] or "").startswith("2009-08-0"), b
        assert "auto-metadaten" not in b["tags"], b
        assert api("GET", "/api/metadata/status")[1]["changedBooks"] == 0

    with subtest("hardcover sync"):
        # the hub writes every 2 s here: wait for its lock
        SQL = f"sqlite3 -cmd '.timeout 5000' {STATE}"
        # a book with the ISBN the stub knows (Hardcover book 900000)
        hid = add_book("Gelesen")
        status, b = api("PATCH", f"/api/books/{hid}", {"identifiers": {"isbn": "9783608938289"}})
        assert status == 200, (status, b)
        machine.wait_until_succeeds(f"test \"$({SQL} 'select hc_book_id from hardcover_books where book_id = {hid}')\" = 900000", timeout=60)
        status, r = api("PUT", f"/api/books/{hid}/progress", {"format": "epub", "position": "epubcfi(/6/4)", "fraction": 0.4, "device": "vm"})
        assert status == 200, (status, r)
        stub = "journalctl -u sources-stub -o cat"
        machine.wait_until_succeeds(f"{stub} | grep -qF 'MUTATION insert_user_book {{\"object\": {{\"book_id\": 900000, \"edition_id\": 900001, \"status_id\": 2}}}}'", timeout=60)
        machine.wait_until_succeeds(f"{stub} | grep 'MUTATION insert_user_book_read' | grep -q started_at", timeout=30)
        # at the end: Read, the open read finished
        status, r = api("PUT", f"/api/books/{hid}/progress", {"format": "epub", "position": "epubcfi(/6/40)", "fraction": 1, "device": "vm"})
        assert status == 200, (status, r)
        machine.wait_until_succeeds(f"{stub} | grep 'MUTATION update_user_book ' | grep -q '\"status_id\": 3'", timeout=60)
        machine.wait_until_succeeds(f"{stub} | grep 'MUTATION update_user_book_read' | grep -q finished_at", timeout=30)
        n = machine.succeed(f"{stub} | grep -c MUTATION").strip()
        assert n == "4", n
        row = machine.succeed(f"{SQL} 'select status, dry_run from hardcover_sync where book_id = {hid}'").strip()
        assert row == "3|0", row
        machine.succeed("journalctl -u calibre-hub -o cat | grep -q 'hardcover sync: progress of arthur every 2 s, writing'")

        # tagged private after the sync: what the hub created is deleted again
        status, b = api("PATCH", f"/api/books/{hid}", {"addTags": ["Private"]})
        assert status == 200, (status, b)
        machine.wait_until_succeeds(f"{stub} | grep -q 'MUTATION delete_user_book {{\"id\": 1001}}'", timeout=60)
        machine.succeed(f"{stub} | grep -q 'MUTATION delete_user_book_read'")
        machine.wait_until_succeeds(f"test $({SQL} 'select dry_run from hardcover_private where book_id = {hid}') = 0", timeout=30)
        assert machine.succeed(f"{SQL} 'select count(*) from hardcover_sync where book_id = {hid}'").strip() == "0"

        # private from the start: never matched or synced
        machine.succeed(f"{DB} add --tags privat --isbn 9780593135648 {epub('Geheim')}")
        gid = book_by_title("Geheim")["id"]
        status, r = api("PUT", f"/api/books/{gid}/progress", {"format": "epub", "position": "epubcfi(/6/4)", "fraction": 0.5, "device": "vm"})
        assert status == 200, (status, r)
        machine.sleep(8)
        assert machine.succeed(f"{SQL} 'select count(*) from hardcover_books where book_id = {gid}'").strip() == "0"
        assert machine.succeed(f"{SQL} 'select count(*) from hardcover_sync where book_id = {gid}'").strip() == "0"
        n = machine.succeed(f"{stub} | grep -c MUTATION").strip()
        assert n == "6", n

    def library_file(book_id, fmt):
        rel = machine.succeed(f"sqlite3 -cmd '.timeout 5000' /srv/books/library/metadata.db \"select b.path || '/' || d.name from books b join data d on d.book = b.id where b.id = {book_id} and d.format = '{fmt.upper()}'\"").strip()
        assert rel, (book_id, fmt)
        return f"/srv/books/library/{rel}.{fmt.lower()}"

    def embed_idle():
        machine.wait_until_succeeds(f"test $(sqlite3 -cmd '.timeout 5000' {STATE} 'select count(*) from embed_queue') = 0", timeout=60)

    META = "QT_QPA_PLATFORM=offscreen ebook-meta"

    with subtest("embed metadata into the files"):
        status, r = api("PUT", f"/api/lists/{lid}/books/1")
        assert status == 200, (status, r)
        machine.wait_until_succeeds("ls /srv/books/boox/Leseliste/*.epub", timeout=30)
        embed_idle()
        status, b = api("PATCH", "/api/books/1", {"title": "Eingebettet", "publisher": "Hub Verlag"})
        assert status == 200 and b["title"] == "Eingebettet", (status, b)
        # several quick edits, one rewrite
        status, b = api("PATCH", "/api/books/1", {"addTags": ["eingebettet"]})
        assert status == 200, (status, b)
        machine.wait_until_succeeds(f"{META} '{library_file(1, 'epub')}' | grep -q '^Title *: Eingebettet$'", timeout=60)
        machine.succeed(f"{META} '{library_file(1, 'epub')}' | grep -q '^Publisher *: Hub Verlag$'")
        machine.wait_until_succeeds(f"{META} '{library_file(1, 'epub')}' | grep -q '^Tags *: .*eingebettet'")
        # the reading list copies the rewritten file again
        machine.wait_until_succeeds(f"{META} /srv/books/boox/Leseliste/*Eingebettet.epub | grep -q '^Title *: Eingebettet$'", timeout=60)
        machine.wait_until_succeeds(f"cmp '{library_file(1, 'epub')}' /srv/books/boox/Leseliste/*Eingebettet.epub", timeout=60)
        # the KOReader checksum of the file before the first rewrite is kept
        n = machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"select count(*) from file_checksums where book_id = 1 and format = 'EPUB' and length(partial_md5) = 32\"").strip()
        assert int(n) >= 1, n
        assert api("GET", "/api/embed/status")[1]["enabled"] is True
        embed_idle()
        status, r = api("DELETE", f"/api/lists/{lid}/books/1")
        machine.wait_until_succeeds("! find /srv/books/boox -name '*.epub' | grep -q .", timeout=30)

    with subtest("convert added books"):
        st = api("GET", "/api/convert/status")[1]
        assert st["enabled"] is True and st["target"] == "EPUB" and st["ignore"] == ["PDF", "CBZ", "CBR"], st
        # an upload: the TXT stays, an EPUB is added
        machine.succeed("printf 'Umwandlung\\n\\nText\\n' > /tmp/Umwandlung.txt")
        r = upload("-F file=@/tmp/Umwandlung.txt")
        assert r["status"] == "imported" and r["book"]["formats"] == ["TXT"], r
        tid = r["book"]["id"]
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{tid} | jq -e '.formats | sort == [\"EPUB\", \"TXT\"]'", timeout=120)
        machine.succeed(f"{META} '{library_file(tid, 'epub')}' | grep -q '^Title *: Umwandlung$'")
        # the inbox: a DOCX
        machine.succeed("printf 'Dokument\\n\\nText\\n' > /tmp/d.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/d.txt /tmp/Dokument.docx --title Dokument --authors 'Doris Docx'")
        machine.succeed("install -m 664 -g calibre-hub /tmp/Dokument.docx /srv/books/inbox/Dokument.docx")
        from_inbox("Dokument.docx")
        did = book_by_title("Dokument")["id"]
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{did} | jq -e '.formats | sort == [\"DOCX\", \"EPUB\"]'", timeout=120)
        # the library: nothing left to convert to EPUB; a PDF-only book would be left alone
        status, r = api("POST", "/api/convert", {})
        assert status == 202, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        assert api("POST", "/api/convert", {"target": "exe"})[0] == 400
        embed_idle()

    PY = "${pkgs.python3}/bin/python3 -I"
    # an EPUB with what the fixer repairs: mimetype compressed and not first,
    # dc:language und, no toc on the spine, a chapter without XML
    # declaration, one in Latin-1, an img without src, links to a body id
    BROKEN_EPUB = "${pkgs.writeText "broken-epub.py" ''
      import sys, zipfile
      container = """<?xml version="1.0"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>"""
      opf = """<?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:title>Kaputte Wiese</dc:title>
          <dc:creator opf:role="aut">Emil Fix</dc:creator>
          <dc:identifier id="id">urn:uuid:8412</dc:identifier>
          <dc:language>und</dc:language>
        </metadata>
        <manifest>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
      </package>"""
      ch1 = """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Eins</title></head>
      <body id="eins"><p>Die Grille sang im Gras.<img/></p><p><a href="ch2.xhtml#zwei">weiter</a></p></body></html>"""
      ch2 = """<?xml version="1.0" encoding="iso-8859-1"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Zwei</title></head>
      <body id="zwei"><p>Größe der Wiese</p></body></html>""".encode("iso-8859-1")
      ncx = """<?xml version="1.0" encoding="utf-8"?>
      <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:uuid:8412"/></head>
      <docTitle><text>Kaputte Wiese</text></docTitle><navMap>
      <navPoint id="n1" playOrder="1"><navLabel><text>Eins</text></navLabel><content src="ch1.xhtml"/></navPoint>
      <navPoint id="n2" playOrder="2"><navLabel><text>Zwei</text></navLabel><content src="ch2.xhtml#zwei"/></navPoint>
      </navMap></ncx>"""
      with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
          z.writestr("META-INF/container.xml", container)
          z.writestr("mimetype", "application/epub+zip")
          z.writestr("OEBPS/content.opf", opf)
          z.writestr("OEBPS/toc.ncx", ncx)
          z.writestr("OEBPS/ch1.xhtml", ch1)
          z.writestr("OEBPS/ch2.xhtml", ch2)
    ''}"
    # what an EPUB checker would complain about in the broken one
    CHECK_EPUB = "${pkgs.writeText "check-epub.py" ''
      import sys, zipfile
      import xml.dom.minidom as minidom
      with zipfile.ZipFile(sys.argv[1]) as z:
          first = z.infolist()[0]
          assert first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED, first
          assert z.read("mimetype") == b"application/epub+zip"
          assert z.testzip() is None
          names = {i.filename for i in z.infolist()}
          assert {"OEBPS/content.opf", "OEBPS/toc.ncx", "OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml"} <= names, names
          opf = z.read("OEBPS/content.opf").decode("utf-8")
          minidom.parseString(opf)
          assert 'toc="ncx"' in opf, opf
          for name in ("OEBPS/ch1.xhtml", "OEBPS/ch2.xhtml", "OEBPS/toc.ncx"):
              raw = z.read(name)
              assert raw.decode("utf-8").startswith('<?xml version="1.0" encoding="utf-8"?>'), (name, raw[:60])
              minidom.parseString(raw)
          ch1 = z.read("OEBPS/ch1.xhtml").decode()
          assert "<img" not in ch1 and 'href="ch2.xhtml"' in ch1 and "Die Grille sang im Gras." in ch1, ch1
          assert "Größe der Wiese" in z.read("OEBPS/ch2.xhtml").decode()
          assert 'src="ch2.xhtml"' in z.read("OEBPS/toc.ncx").decode()
    ''}"

    with subtest("epub fixer"):
        st = api("GET", "/api/epub-fix/status")[1]
        assert st["onImport"] is True and st["keepOriginal"] is True, st
        machine.succeed(f"{PY} {BROKEN_EPUB} /tmp/wiese.epub")
        machine.fail(f"{PY} {CHECK_EPUB} /tmp/wiese.epub")
        machine.succeed("install -m 664 -g calibre-hub /tmp/wiese.epub /srv/books/inbox/Wiese.epub")
        from_inbox("Wiese.epub")
        wid = book_by_title("Kaputte Wiese")["id"]
        # repaired on import; the file as it was kept as ORIGINAL_EPUB
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{wid} | jq -e '.formats | sort == [\"EPUB\", \"ORIGINAL_EPUB\"]'", timeout=120)
        machine.wait_until_succeeds(f"{PY} {CHECK_EPUB} '{library_file(wid, 'epub')}'", timeout=60)
        machine.fail(f"{PY} {CHECK_EPUB} '{library_file(wid, 'original_epub')}'")
        machine.succeed(f"{META} '{library_file(wid, 'epub')}' | grep -q '^Title *: Kaputte Wiese$'")
        machine.succeed(f"QT_QPA_PLATFORM=offscreen ebook-convert '{library_file(wid, 'epub')}' /tmp/wiese.txt")
        machine.succeed("grep -q 'Größe der Wiese' /tmp/wiese.txt")
        # the KOReader checksum before the repair
        n = machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"select count(*) from file_checksums where book_id = {wid} and format = 'EPUB'\"").strip()
        assert int(n) >= 1, n
        st = api("GET", "/api/epub-fix/status")[1]
        assert st["lastRun"]["from"] == "added" and st["lastRun"]["dryRun"] is False, st
        # the library as a dry run: nothing left to repair in that book
        assert api("POST", "/api/epub-fix", {"dryRun": "ja"})[0] == 400
        status, r = api("POST", "/api/epub-fix", {})
        assert status == 202 and r["dryRun"] is True and r["total"] >= 1, (status, r)
        j = wait_job(r["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        status, res = api("GET", f"/api/epub-fix/jobs/{r['jobId']}")
        assert status == 200 and res["booksFixed"] == 0, (status, res)
        assert not any(b["bookId"] == wid and b["fixes"] for b in res["results"]), res
        assert api("GET", "/api/epub-fix/jobs/nope")[0] == 404
        embed_idle()

    with subtest("backlog import"):
        import base64

        def put(path, data):
            if isinstance(data, str):
                data = data.encode()
            machine.succeed(f"mkdir -p \"$(dirname '{path}')\" && echo {base64.b64encode(data).decode()} | base64 -d > '{path}'")

        def opf(title, author, extra=""):
            return f"""<?xml version='1.0' encoding='utf-8'?>
    <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:identifier opf:scheme="calibre" id="calibre_id">12</dc:identifier>
        <dc:title>{title}</dc:title>
        <dc:creator opf:file-as="x" opf:role="aut">{author}</dc:creator>
        {extra}
      </metadata>
    </package>
    """

        def pdf(fill=b"x"):
            objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>"]
            out = b"%PDF-1.4\n%" + fill * 3000 + b"\n"
            offsets = []
            for i, o in enumerate(objs, 1):
                offsets.append(len(out))
                out += b"%d 0 obj\n" % i + o + b"\nendobj\n"
            xref = len(out)
            out += b"xref\n0 4\n0000000000 65535 f \n" + b"".join(b"%010d 00000 n \n" % x for x in offsets)
            return out + b"trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % xref

        ALT = "/srv/books/alt"
        CAL = f"{ALT}/Ada Writer/Altes Buch (12)"
        # an old calibre library folder: metadata.opf, cover.jpg, two formats
        machine.succeed("printf 'Altes Buch\\n\\nText\\n' > /tmp/alt.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/alt.txt /tmp/alt.epub --title 'Falscher Titel' --authors 'Niemand'")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/alt.epub /tmp/alt.azw3")
        machine.succeed(f"mkdir -p '{CAL}' && cp /tmp/alt.epub '{CAL}/Altes Buch - Ada Writer.epub' && cp /tmp/alt.azw3 '{CAL}/Altes Buch - Ada Writer.azw3'")
        machine.succeed(f"QT_QPA_PLATFORM=offscreen ebook-meta /tmp/alt.epub --get-cover='{CAL}/cover.jpg'")
        put(f"{CAL}/metadata.opf", opf("Altes Buch", "Ada Writer", """
        <dc:identifier opf:scheme="ISBN">978-0-306-40615-7</dc:identifier>
        <dc:subject>Geschichte</dc:subject>
        <dc:publisher>Alter Verlag</dc:publisher>
        <dc:date>1999-05-01T00:00:00+00:00</dc:date>
        <dc:language>deu</dc:language>
        <meta content="Alte Reihe" name="calibre:series"/>
        <meta content="3.0" name="calibre:series_index"/>"""))
        # the inbox's book in a format the library lacks
        ib = book_by_title("Inboxbuch")
        assert "AZW3" not in ib["formats"], ib
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/k.txt '/tmp/ib.azw3' --title Inboxbuch --authors 'Agatha Test'")
        machine.succeed(f"mkdir -p '{ALT}/Agatha Test/Inboxbuch (7)' && cp /tmp/ib.azw3 '{ALT}/Agatha Test/Inboxbuch (7)/Inboxbuch.azw3'")
        put(f"{ALT}/Agatha Test/Inboxbuch (7)/metadata.opf", opf("Inboxbuch", "Agatha Test"))
        # a plain folder, a file that isn't a book, a copy of a book the library has
        put(f"{ALT}/Some Author/book.pdf", pdf())
        put(f"{ALT}/Some Author/talk.mp3", b"ID3" + b"\0" * 4000)
        machine.succeed(f"mkdir -p '{ALT}/Krimi' && cp /srv/books/inbox/_imported/*/Roman/Krimi/k.epub '{ALT}/Krimi/k.epub'")

        # what the next subtests take, in the same pass of the analysis
        WW = f"{ALT}/Algebra"
        carr_name = "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).pdf"
        # fill bytes no earlier file of the test has (same file = duplicate)
        put(f"{WW}/{carr_name}", pdf(b"q"))
        # a scan without a text layer: Tesseract reads it in the analysis, the
        # ISBN is in the book, the stub's catalogs don't know it
        FLOW = f"{ALT}/Flow"
        machine.succeed(f"mkdir -p {FLOW} && cp ${../spec/fixtures/metadata/scan.pdf} '{FLOW}/Herbert - Der Wuestenplanet.pdf' && "
                        f"cp ${../spec/fixtures/metadata/scan.djvu} '{FLOW}/Herbert - Dune Messias.djvu' && chmod -R u+w {FLOW}")
        # a MOBI through calibre's tools; a text with the same fill would be a duplicate
        machine.succeed(f"printf 'A Quiet Book\\n\\nby Jane Roe\\n\\nCopyright 2001. ISBN 0-201-91465-4\\n' > /tmp/quiet.txt && "
                        f"QT_QPA_PLATFORM=offscreen ebook-convert /tmp/quiet.txt '{FLOW}/Roe - A Quiet Book.mobi' --title 'A Quiet Book' --authors 'Jane Roe' >/dev/null")
        # old enough to be looked at
        machine.succeed(f"find {ALT} -type f -exec touch -d '1 hour ago' {{}} +")

        # the Eingang: nothing to start, it looks at the roots by itself
        status, intake = api("GET", "/api/intake")
        assert status == 200 and intake["enabled"] is True and intake["progress"]["state"] in ("idle", "scanning", "analysing", "paused"), intake
        assert api("GET", "/api/intake/0")[0] == 404
        # the old ways in are gone
        for method, path in [("POST", "/api/import"), ("GET", "/api/import"), ("GET", "/api/import/runs/x"), ("GET", "/api/import/quality"),
                             ("GET", "/api/import/repair"), ("POST", "/api/import/repair/accept"), ("POST", "/api/import/repair/reject")]:
            assert api(method, path, {} if method == "POST" else None)[0] == 404, path
        assert machine.execute(f"CALIBRE_HUB_URL={H} CALIBRE_HUB_TOKEN_FILE=/etc/hub/token hub import '{ALT}'")[0] == 1
        out = machine.succeed(f"CALIBRE_HUB_URL={H} CALIBRE_HUB_TOKEN_FILE=/etc/hub/token hub eingang")
        assert "taken by itself: backlog off, inbox from 60, upload from 60" in out, out

        # an old calibre folder takes its metadata.opf and cover, no folder as a category
        e = entry("Altes Buch - Ada Writer.epub")
        assert e["origin"] == "backlog" and e["kind"] == "calibre", e
        decide(e, "accept")
        old = book_by_title("Altes Buch")
        old = api("GET", f"/api/books/{old['id']}")[1]
        assert old["title"] == "Altes Buch" and old["authors"] == ["Ada Writer"], old
        assert old["series"] == "Alte Reihe" and old["seriesIndex"] == 3.0 and old["publisher"] == "Alter Verlag", old
        assert old["identifiers"].get("isbn") == "9780306406157" and old["languages"] == ["deu"], old
        assert set(old["formats"]) >= {"EPUB", "AZW3"}, old
        # no folder as category or tag
        assert [t for t in old["tags"] if t != "auto-metadaten"] == ["Geschichte"] and old["custom"]["kategorie"] is None, old
        assert code(f"-b /tmp/jar {H}/api/books/{old['id']}/cover") == "200"
        # a file that says nothing
        e = entry("book.pdf")
        assert e["folder"] == "Some Author", e
        decide(e, "file")
        machine.succeed(f"test -f '{ALT}/Some Author/book.pdf'")
        # a format the library lacks goes to the book it has
        e = entry("Inboxbuch.azw3")
        assert e["action"] == "addFormats" and e["bookId"] == ib["id"], e
        decide(e, "accept")
        assert "AZW3" in book_by_title("Inboxbuch")["formats"]
        assert not [e for e in api("GET", "/api/intake?limit=500")[1]["entries"] if e["name"] in ("book.pdf", "Inboxbuch.azw3")]

    with subtest("the Eingang reads file names (#8408)"):
        # "Author - Title (Publisher, Year)": calibre alone made it the title
        # "Carr" by "Formulas" and "Theorems in Pure Mathematics 2e (Chelsea, 1970)"
        e = entry(carr_name)
        assert e["proposal"]["title"] == "Formulas and Theorems in Pure Mathematics" and e["proposal"]["authors"] == ["Carr"], e
        decide(e, "accept")
        carr = book_by_title("Formulas and Theorems in Pure Mathematics")
        carr = api("GET", f"/api/books/{carr['id']}")[1]
        assert carr["authors"] == ["Carr"] and carr["publisher"] == "Chelsea" and carr["pubdate"].startswith("1970-01"), carr

        # a book added the old way (calibre's add-book with the file name, as
        # the import did before): a recheck proposes the fix in the Eingang
        brass = "Brass - Advanced Data Structures (Cambridge, 2008).pdf"
        put(f"{WW}/{brass}", pdf(b"r"))
        out = machine.succeed(f"curl -sf --user scripts:scripts-secret -X POST --data-binary '@{WW}/{brass}' "
                              f"'http://127.0.0.1:8083/cdb/add-book/1/y/{urllib.parse.quote(brass)}/library'")
        old_id = json.loads(out)["book_id"]
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar {H}/api/books/{old_id}", timeout=30)
        old = api("GET", f"/api/books/{old_id}")[1]
        assert old["title"] == "Brass" and old["authors"] == ["Advanced Data Structures (Cambridge, 2008)"], old
        machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"insert into import_files (path, size, mtime, status, book_id, run_id, at) "
                        f"values ('{WW}/{brass}', 1, 1, 'imported', {old_id}, 'old', strftime('%s', 'now'))\"")
        out = machine.succeed(f"CALIBRE_HUB_URL={H} CALIBRE_HUB_TOKEN_FILE=/etc/hub/token hub eingang recheck --run old")
        assert "recheck: 1 books" in out, out
        for _ in range(180):
            status, e = api("GET", f"/api/intake/{-old_id}")
            if status == 200:
                break
            machine.sleep(5)
        assert status == 200, (status, e)
        planned = {c["field"]: c["new"] for c in e["changes"]}
        assert e["decided"] == "name" and e["kind"] == "library" and e["confidence"] == 70 and e["level"] == 3, e
        assert planned["title"] == "Advanced Data Structures" and planned["authors"] == ["Brass"], e
        assert planned["publisher"] == "Cambridge University Press" and planned["pubdate"] == "2008", e
        assert api("GET", f"/api/books/{old_id}")[1]["title"] == "Brass"
        status, acc = api("POST", "/api/intake/decide", {"target": {"ids": [-old_id]}, "decision": "accept"})
        assert status == 202 and acc["total"] == 1, (status, acc)
        j = wait_job(acc["jobId"])
        assert j["status"] == "done" and j["errors"] == [], j
        fixed = api("GET", f"/api/books/{old_id}")[1]
        assert fixed["title"] == "Advanced Data Structures" and fixed["authors"] == ["Brass"], fixed
        log = api("GET", f"/api/metadata/changes?bookId={old_id}")[1]["changes"]
        assert any(c["field"] == "title" and c["source"] == "rules" and c["old"] == "Brass" for c in log), log

    with subtest("the rule flow reads the book first (#8528)"):
        names = ["Herbert - Der Wuestenplanet.pdf", "Herbert - Dune Messias.djvu", "Roe - A Quiet Book.mobi"]
        for name in names:
            decide(entry(name), "accept")
        sql = lambda q: machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"{q}\"").strip()
        # both scans; the key starts with the file's size
        scans = sql("select front from ocr_pages where key like '16041-%' or key like '25722-%'")
        assert scans.count("Herbert") == 2, scans
        mobi = book_by_title("A Quiet Book")["id"]
        assert sql(f"select level || ' ' || confidence from metadata_decisions where book_id = {mobi}") == "2 90"
        # calibre finds a book by its ISBN in both forms: the same ISBN on two books
        machine.succeed(f"{DB} set_metadata {mobi} -f identifiers:isbn:9780201914658")
        machine.wait_until_succeeds(f"curl -sf -b /tmp/jar '{H}/api/books?q=identifiers:%22=isbn:=9780201914658%22' | grep -q '\"id\":{mobi}'", timeout=30)

    with subtest("the Eingang decides (#8605)"):
        IN = f"{ALT}/Eingang"
        TRASH = f"{ALT}-papierkorb/Eingang"
        machine.succeed(f"install -d -m 2775 -g calibre-hub '{IN}'")
        put(f"{IN}/Ada Writer - Angenommen.pdf", pdf(b"s"))
        put(f"{IN}/wegwerfen.pdf", pdf(b"t"))
        # byte for byte a file of the library: nobody has to look at it
        copy = machine.succeed("find /srv/books/library -name '*.pdf' | head -1").strip()
        machine.succeed(f"cp '{copy}' '{IN}/kopie.pdf' && touch -d '1 hour ago' '{IN}'/*.pdf")
        machine.wait_until_succeeds(f"test -f '{TRASH}/kopie.pdf'", timeout=600)
        assert machine.succeed(f"cmp '{copy}' '{TRASH}/kopie.pdf' && test ! -e '{IN}/kopie.pdf' && echo ok").strip() == "ok"

        # thrown away: out of the root, under its path, the hub's sandbox lets it
        gone = entry("wegwerfen.pdf")
        status, r = api("POST", "/api/intake/decide", {"target": {"ids": [gone["id"]]}, "decision": "trash"})
        assert status == 202, (status, r)
        j = wait_job(r["jobId"], 60)
        assert j["status"] == "done" and j["errors"] == [], j
        machine.succeed(f"test -f '{TRASH}/wegwerfen.pdf' && test ! -e '{IN}/wegwerfen.pdf'")

        # accepted with an edited title: a book like any import's, the file stays
        kept = entry("Ada Writer - Angenommen.pdf")
        status, r = api("POST", "/api/intake/decide", {"target": {"ids": [kept["id"]]}, "decision": "accept", "title": "Von Hand", "authors": ["Ada Writer"]})
        assert status == 202, (status, r)
        j = wait_job(r["jobId"], 120)
        assert j["status"] == "done" and j["errors"] == [], j
        assert book_by_title("Von Hand")["authors"] == ["Ada Writer"]
        machine.succeed(f"test -f '{IN}/Ada Writer - Angenommen.pdf'")
        assert not [e for e in api("GET", "/api/intake?limit=500")[1]["entries"] if e["id"] == kept["id"]]

        # a root's parent is writable for the hub, the library in it isn't
        pid = machine.succeed("systemctl show -p MainPID --value calibre-hub").strip()
        machine.fail(f"nsenter -t {pid} -m touch /srv/books/library/from-the-hub")
        machine.succeed(f"nsenter -t {pid} -m touch /srv/books/from-the-hub && rm /srv/books/from-the-hub")

        # the inbox's and an upload's trash: one rename next to their root,
        # with the service's sandbox around it
        assert api("POST", "/api/intake/threshold", {"origin": "inbox", "value": None})[0] == 200
        assert api("POST", "/api/intake/threshold", {"origin": "upload", "value": None})[0] == 200
        machine.succeed("printf 'Weg\\n\\nText\\n' > /tmp/w.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/w.txt /tmp/Wegwerfbuch.epub --title Wegwerfbuch --authors 'Walter Weg'")
        machine.succeed("install -d -m 2775 -g calibre-hub /srv/books/inbox/Weg && install -m 664 -g calibre-hub /tmp/Wegwerfbuch.epub /srv/books/inbox/Weg/Wegwerfbuch.epub")
        decide(entry("Wegwerfbuch.epub", "&origin=inbox", 120), "trash")
        machine.succeed("test -f /srv/books/inbox-papierkorb/Weg/Wegwerfbuch.epub && test ! -e /srv/books/inbox/Weg/Wegwerfbuch.epub")
        machine.succeed("cp /tmp/Wegwerfbuch.epub /tmp/Hochgeladen-weg.epub")
        status, r = api("POST", "/api/books", extra="-F file=@/tmp/Hochgeladen-weg.epub")
        assert status == 202, (status, r)
        e = entry("Hochgeladen-weg.epub", "&origin=upload", 120)
        decide(e, "trash")
        assert api("GET", f"/api/intake/uploads/{r['upload']['id']}")[1]["status"] == "trashed"
        machine.succeed(f"test -f /var/lib/calibre-hub/uploads-papierkorb/{r['upload']['id']}/Hochgeladen-weg.epub")

    with subtest("cleanup of inbox imports"):
        ib = book_by_title("Inboxbuch")
        assert ib["custom"]["kategorie"] == "Roman.Krimi" and {"Krimi", "Roman"} <= set(ib["tags"]), ib
        params = {"minId": ib["id"], "maxId": ib["id"]}
        status, dry = api("POST", "/api/import/cleanup", params)
        assert status == 200 and dry["total"] == 1, (status, dry)
        e = dry["entries"][0]
        assert e["folders"] == ["Roman", "Krimi"] and sorted(e["removeTags"]) == ["Krimi", "Roman"] and e["clearKategorie"], e
        status, c = api("POST", "/api/import/cleanup", {**params, "dryRun": False})
        assert status == 202, (status, c)
        assert wait_job(c["job"]["id"])["status"] == "done"
        b = book_by_title("Inboxbuch")
        assert b["custom"]["kategorie"] is None and not {"Krimi", "Roman"} & set(b["tags"]), b
        machine.succeed(f"test -s /var/lib/calibre-hub/import-cleanup-{c['id']}.json")
        assert api("POST", "/api/import/cleanup", params)[1]["total"] == 0
        status, u = api("POST", f"/api/import/cleanups/{c['id']}/undo", {"dryRun": False})
        assert status == 202, (status, u)
        assert wait_job(u["undoJob"]["id"])["status"] == "done"
        b = book_by_title("Inboxbuch")
        assert b["custom"]["kategorie"] == "Roman.Krimi" and {"Krimi", "Roman"} <= set(b["tags"]), b

    with subtest("failing handler is parked and alerts"):
        machine.succeed("printf 'x\\n' > /tmp/x.txt")
        machine.succeed("QT_QPA_PLATFORM=offscreen ebook-convert /tmp/x.txt /tmp/kaputt.epub --title Kaputt --authors Niemand")
        machine.succeed(f"{DB} add /tmp/kaputt.epub")
        machine.wait_until_succeeds("grep -q '90-fail failed' /var/lib/calibre-hub/alerts.log", timeout=120)

    with subtest("deleted"):
        machine.succeed(f"{DB} remove 1")
        machine.wait_until_succeeds("grep -q '\"deleted\",1,' /var/lib/calibre-hub/events.log", timeout=30)

    with subtest("restart does not repeat events"):
        embed_idle()
        before = machine.succeed("wc -l < /var/lib/calibre-hub/events.log").strip()
        machine.systemctl("restart calibre-hub.service")
        machine.wait_for_open_port(8084)
        machine.sleep(10)
        after = machine.succeed("wc -l < /var/lib/calibre-hub/events.log").strip()
        assert before == after, (before, after)

    with subtest("hub restart and update leave calibre-server running"):
        def invocation(unit):
            return machine.succeed(f"systemctl show -p InvocationID --value {unit}").strip()
        server, hub = invocation("calibre-server.service"), invocation("calibre-hub.service")
        machine.systemctl("restart calibre-hub.service")
        machine.wait_for_open_port(8084)
        assert invocation("calibre-server.service") == server
        assert invocation("calibre-hub.service") != hub
        hub = invocation("calibre-hub.service")
        machine.succeed("/run/current-system/specialisation/hub-update/bin/switch-to-configuration test")
        machine.wait_for_open_port(8084)
        machine.succeed("systemctl show -p ExecStart calibre-hub.service | grep -q calibre-hub-update")
        assert invocation("calibre-hub.service") != hub, "hub not restarted by the update"
        assert invocation("calibre-server.service") == server, "calibre-server restarted by a hub update"
        n = machine.succeed("sqlite3 -cmd '.timeout 5000' /srv/books/library/metadata.db \"select count(*) from sqlite_master where type = 'trigger' and name like 'hub_%'\"").strip()
        assert int(n) > 10, n
        assert code(f"-b /tmp/jar {H}/api/books") == "200"

    def as_lea(method, path, body=None):
        data = f"-H 'Content-Type: application/json' -d '{json.dumps(body)}'" if body is not None else ""
        out = machine.succeed(f"curl -s -b /tmp/lea -X {method} {CSRF} {data} -w '\\n%{{http_code}}' '{H}{path}'")
        text, status = out.rsplit("\n", 1)
        return int(status), (json.loads(text) if text.strip() else None)

    LEA_TOK = "-H 'Authorization: Bearer lea-token-0123456789abcdef'"

    with subtest("two users: own login, own lists and progress, readers don't write"):
        assert code(f"-c /tmp/lea -X POST {CSRF} -d '{{\"user\":\"lea\",\"password\":\"login-secret\"}}' {H}/api/session") == "401"
        assert code(f"-c /tmp/lea -X POST {CSRF} -d '{{\"user\":\"lea\",\"password\":\"lea-secret\"}}' {H}/api/session") == "200"
        assert as_lea("GET", "/api/session") == (200, {"user": "lea", "role": "reader", "sync": True})
        assert api("GET", "/api/session") == (200, {"user": "arthur", "role": "admin", "sync": True})
        users = machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} 'select name, role, active from users order by name'").split()
        assert users == ["arthur|admin|1", "lea|reader|1"], users
        # a book with an EPUB (the newest ones may be PDFs of the backlog import)
        bid = next(b["id"] for b in api("GET", "/api/books?limit=100")[1]["books"] if "EPUB" in b["formats"])
        # reads and downloads
        assert as_lea("GET", f"/api/books/{bid}")[0] == 200
        assert code(f"-b /tmp/lea {H}/api/books/{bid}/download/epub") == "200"
        # no changes to the library, also not with her token
        assert as_lea("PATCH", f"/api/books/{bid}", {"title": "Lea war hier"})[0] == 403
        assert as_lea("POST", "/api/books/bulk", {"target": {"ids": [bid]}, "changes": {"addTags": ["x"]}})[0] == 403
        assert as_lea("DELETE", f"/api/books/{bid}")[0] == 403
        assert code(f"{LEA_TOK} -X PATCH -H 'Content-Type: application/json' -d '{{\"title\":\"x\"}}' {H}/api/books/{bid}") == "403"
        assert json.loads(machine.succeed(f"curl -sf {LEA_TOK} {H}/api/session")) == {"user": "lea", "role": "reader", "sync": True}
        assert api("GET", f"/api/books/{bid}")[1]["title"] != "Lea war hier"
        # her own list, unseen by arthur; his private lists unseen by her
        status, l = as_lea("POST", "/api/lists", {"name": "Leas Liste"})
        assert status in (200, 201) and l["owner"] == "lea", (status, l)
        assert as_lea("PUT", f"/api/lists/{l['id']}/books/{bid}")[0] in (200, 201)
        # synced into her own reader folder, not into arthur's
        assert as_lea("PATCH", f"/api/lists/{l['id']}", {"sync": True})[0] == 200
        machine.wait_until_succeeds("ls '/srv/books/boox-lea/Leas Liste/' | grep -q .", timeout=60)
        machine.succeed("test ! -e '/srv/books/boox/Leas Liste'")
        # arthur's editable list: books yes, its settings no (sync off would empty his e-reader folder)
        status, shared = api("POST", "/api/lists", {"name": "Gemeinsam", "visibility": "editable", "sync": True})
        assert status == 201, (status, shared)
        assert as_lea("PUT", f"/api/lists/{shared['id']}/books/{bid}")[0] in (200, 201)
        assert as_lea("PATCH", f"/api/lists/{shared['id']}", {"sync": False})[0] == 403
        assert as_lea("PATCH", f"/api/lists/{shared['id']}", {"visibility": "private"})[0] == 403
        assert as_lea("PATCH", f"/api/lists/{shared['id']}", {"name": "Weg"})[0] == 403
        s = api("GET", f"/api/lists/{shared['id']}")[1]
        assert s["sync"] and s["visibility"] == "editable" and s["name"] == "Gemeinsam", s
        assert api("DELETE", f"/api/lists/{shared['id']}")[0] == 200
        leas =[x["name"] for x in as_lea("GET", "/api/lists")[1]]
        arthurs = [x["name"] for x in api("GET", "/api/lists")[1]]
        assert "Leas Liste" in leas and "Leseliste" not in leas, leas
        assert "Leas Liste" not in arthurs and "Leseliste" in arthurs, arthurs
        assert as_lea("GET", f"/api/books?list={l['id']}")[1]["total"] == 1
        assert l["id"] not in api("GET", f"/api/books/{bid}")[1].get("lists", [])
        # her own reading progress
        assert as_lea("PUT", f"/api/books/{bid}/progress", {"format": "epub", "position": "epubcfi(/6/8)", "fraction": 0.7, "device": "lea-phone"})[0] == 200
        assert as_lea("GET", f"/api/books/{bid}/progress")[1]["latest"]["device"] == "lea-phone"
        assert "lea-phone" not in [d["device"] for d in api("GET", f"/api/books/{bid}/progress")[1]["devices"]]
        # OPDS with her password shows her lists
        nav = machine.succeed(f"curl -sf -u lea:lea-secret {H}/opds/lists")
        assert "Leas Liste" in nav and "Leseliste" not in nav, nav
        assert code(f"-u lea:lea-secret {H}/opds") == "200"
        # the library's upkeep pages are arthur's
        assert as_lea("GET", "/api/trash")[0] == 403
        assert as_lea("GET", "/api/metadata/changes")[0] == 403
        assert api("GET", "/api/trash")[0] == 200

    with subtest("private tags: each user's own, never in calibre"):
        # bid: the book in Leas Liste (two users), other: any other one
        other = next(b["id"] for b in api("GET", "/api/books?limit=2&sort=title")[1]["books"] if b["id"] != bid)
        status, r = api("POST", "/api/private-tags", {"bookIds": [bid, other, 999999], "add": ["Geheim"]})
        assert status == 200 and r == {"total": 2, "changed": sorted([bid, other])}, (status, r)
        status, r = as_lea("PUT", f"/api/books/{bid}/private-tags", {"tags": ["Leas", "geheim"]})
        assert status == 200 and r["privateTags"] == ["geheim", "Leas"], (status, r)
        assert api("GET", f"/api/books/{bid}")[1]["privateTags"] == ["Geheim"]
        assert as_lea("GET", f"/api/books/{bid}")[1]["privateTags"] == ["geheim", "Leas"]
        assert as_lea("GET", f"/api/books/{other}")[1]["privateTags"] == []
        # calibre's tags, shared by everyone, stay as they were
        tags = api("GET", f"/api/books/{bid}")[1]["tags"]
        assert not any(t.lower() in ("geheim", "leas") for t in tags), tags
        assert not any(t["name"].lower() in ("geheim", "leas") for t in api("GET", "/api/categories")[1]["tags"])
        assert api("GET", "/api/categories")[1]["privateTags"] == [{"name": "Geheim", "count": 2}]
        assert as_lea("GET", "/api/private-tags")[1] == [{"name": "geheim", "count": 1}, {"name": "Leas", "count": 1}]
        # filtering: only her own tags find books for her
        assert api("GET", "/api/books?ptag=Geheim")[1]["total"] == 2
        assert api("GET", "/api/books?ptag=Leas")[1]["total"] == 0
        page = as_lea("GET", "/api/books?ptag=Leas&ptag=GEHEIM")[1]
        assert page["total"] == 1 and page["books"][0]["id"] == bid, page
        assert as_lea("GET", f"/api/books?ptag=Leas&list={l['id']}")[1]["total"] == 1
        # a selection by her tag: the tag off again
        status, r = as_lea("POST", "/api/private-tags", {"target": {"query": {"ptag": ["Leas"]}, "expect": 1}, "remove": ["Leas"]})
        assert status == 200 and r["changed"] == [bid], (status, r)
        assert as_lea("GET", "/api/books?ptag=Leas")[1]["total"] == 0
        assert as_lea("POST", "/api/private-tags", {"bookIds": [bid], "add": ["a,b"]})[0] == 400
        # arthur's bulk edit by his private tag
        status, job = api("POST", "/api/books/bulk", {"target": {"query": {"ptag": ["Geheim"]}, "expect": 2}, "changes": {"rating": 6}})
        assert status == 202 and job["total"] == 2, (status, job)
        wait_job(job["jobId"])
        assert as_lea("GET", "/api/private-tags")[1] == [{"name": "geheim", "count": 1}]
        rows = machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} 'select owner, book_id, tag from private_tags order by owner, book_id'").split()
        assert sorted(rows) == sorted([f"arthur|{bid}|Geheim", f"arthur|{other}|Geheim", f"lea|{bid}|geheim"]), rows

    with subtest("opds with basic auth"):
        assert code(f"{H}/opds") == "401"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"

    with subtest("a single-user configuration (login user and tokens) keeps working"):
        machine.succeed(f"{BASE}/specialisation/single-user/bin/switch-to-configuration test")
        machine.wait_for_open_port(8084)
        machine.wait_until_succeeds("journalctl -u calibre-hub -o cat | grep -qx 'users: arthur (admin)'", timeout=30)
        # his session, his token and his password as before; her login is gone
        assert api("GET", "/api/session") == (200, {"user": "arthur", "role": "admin", "sync": True})
        assert code(f"-H 'Authorization: Bearer cli-token-0123456789abcdef' {H}/api/books") == "200"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"
        assert as_lea("GET", "/api/session")[0] == 401
        assert code(f"{LEA_TOK} {H}/api/books") == "401"
        # her data stays, she can't log in
        users = machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} 'select name, role, active from users order by name'").split()
        assert users == ["arthur|admin|1", "lea|reader|0"], users
        assert machine.succeed(f"sqlite3 -cmd '.timeout 5000' {STATE} \"select count(*) from lists where owner = 'lea'\"").strip() == "1"

    with subtest("calibre-server down -> 502"):
        machine.systemctl("stop calibre-server.service")
        assert code(f"-b /tmp/jar {H}/api/books") == "502"
  '';
}
