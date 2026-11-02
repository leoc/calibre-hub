# NixOS VM test: calibre-server + calibre-hub from the module, an empty
# library, one book added through calibre-server. Also the smoke test against
# the calibre version of the pinned nixpkgs.
{ pkgs, module }:
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
        # the CLI, as calibre-hub cli and hub
        config.services.calibre-hub.package
      ];
      environment.etc = {
        "hub/service".text = "service-secret";
        "hub/login".text = "login-secret\n";
        "hub/key".text = "0123456789abcdef0123456789abcdef";
        "hub/scripts".text = "scripts-secret";
        "hub/token".text = "cli-token-0123456789abcdef\n";
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
          paths = [ (pkgs.callPackage ./package.nix { }) ];
          meta.mainProgram = "calibre-hub";
        }
      );
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
      systemd.tmpfiles.rules = [
        "d /srv/books/library 2775 calibre-server calibre-hub -"
        "d /srv/books/inbox 2775 root calibre-hub -"
        "d /srv/books/boox 2775 root calibre-hub -"
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

    def api(method, path, body=None, extra=""):
        data = f"-H 'Content-Type: application/json' -d '{json.dumps(body)}'" if body is not None else ""
        out = machine.succeed(f"curl -s -b /tmp/jar -X {method} {CSRF} {data} {extra} -w '\\n%{{http_code}}' '{H}{path}'")
        text, status = out.rsplit("\n", 1)
        return int(status), (json.loads(text) if text.strip() else None)

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
        status, r = api("POST", "/api/books", extra=form)
        assert status == 201 and sorted(r["book"]["tags"]) == ["Neu", "Roman"] and r["book"]["custom"]["kategorie"] == "Roman.Krimi", (status, r)
        uid = r["book"]["id"]
        machine.wait_until_succeeds(f"grep -q '\"added\",{uid},' /var/lib/calibre-hub/events.log", timeout=30)
        status, r = api("POST", "/api/books", extra="-F file=@/tmp/Upload.epub")
        assert status == 409 and r["error"] == "duplicate" and r["duplicates"][0]["id"] == uid, (status, r)
        status, r = api("POST", "/api/books", extra="-F file=@/tmp/Upload.epub -F force=1")
        assert status == 201 and r["book"]["id"] != uid, (status, r)
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
        machine.succeed(f"journalctl -u calibre-hub -o cat | grep -q 'resuming job {r['jobId']} at '")
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
        pref = machine.succeed("sqlite3 /srv/books/library/metadata.db \"select val from preferences where key = 'expire_old_trash_after'\"").strip()
        assert int(pref) >= 100 * 365 * 86400, pref
        status, b = api("PATCH", f"/api/books/{uid}", {"addTags": ["leseliste"]})
        assert status == 200, (status, b)
        mirrored = "find /srv/books/boox -name '*Hochgeladen.epub' | grep -q ."
        machine.wait_until_succeeds(mirrored, timeout=30)
        assert code(f"-b /tmp/jar -X DELETE {H}/api/books/{uid}") == "403"
        status, r = api("DELETE", f"/api/books/{uid}")
        assert status == 200 and r["book"]["id"] == uid and r["book"]["title"] == "Hochgeladen", (status, r)
        assert api("GET", f"/api/books/{uid}")[0] == 404
        assert api("DELETE", f"/api/books/{uid}")[0] == 404
        machine.wait_until_succeeds(f"grep -q '\"deleted\",{uid},' /var/lib/calibre-hub/events.log", timeout=30)
        machine.wait_until_succeeds(f"! {mirrored}", timeout=30)
        machine.succeed(f"test -f /srv/books/library/.caltrash/b/{uid}/metadata.opf")
        status, trash = api("GET", "/api/trash")
        entry = next(e for e in trash if e["id"] == uid)
        assert entry["title"] == "Hochgeladen" and entry["authors"] == ["Ulla Upload"], entry
        assert sorted(entry["formats"]) == ["EPUB", "TXT"] and entry["deletedAt"], entry
        status, r = api("POST", f"/api/trash/{uid}/restore")
        assert status == 200, (status, r)
        rb = r["book"]
        assert rb["title"] == "Hochgeladen" and rb["authors"] == ["Ulla Upload"], rb
        assert sorted(rb["formats"]) == ["EPUB", "TXT"] and "leseliste" in rb["tags"], rb
        assert rb["custom"]["kategorie"] == b["custom"]["kategorie"] and rb["series"] == b["series"], (rb, b)
        added = lambda x: datetime.fromisoformat(x["added"]).replace(microsecond=0)
        assert added(rb) == added(b), (rb, b)
        rid = rb["id"]
        assert code(f"-b /tmp/jar '{H}/api/books/{rid}/cover'") == "200"
        machine.wait_until_succeeds(f"grep -q '\"added\",{rid},' /var/lib/calibre-hub/events.log", timeout=30)
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
        status, r = api("POST", "/api/books", extra=f"-F file=@{epub('Fern')} -F kategorie=Roman.SF")
        assert status == 201, (status, r)
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
        n = machine.succeed("sqlite3 /srv/books/library/metadata.db \"select count(*) from sqlite_master where type = 'trigger' and name like 'hub_%'\"").strip()
        assert int(n) > 10, n
        assert code(f"-b /tmp/jar {H}/api/books") == "200"

    with subtest("opds with basic auth"):
        assert code(f"{H}/opds") == "401"
        assert code(f"-u arthur:login-secret {H}/opds") == "200"

    with subtest("calibre-server down -> 502"):
        machine.systemctl("stop calibre-server.service")
        assert code(f"-b /tmp/jar {H}/api/books") == "502"
  '';
}
