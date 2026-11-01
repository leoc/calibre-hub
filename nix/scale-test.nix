# Scale test: 10,000 books without files (metadata events don't need them).
# Measures first start, single and bulk changes, an offline rename and the
# nightly reconcile. Not part of `nix flake check` (slow under emulation):
#   nix build .#scale-test -L
# Results are printed as "SCALE ..." lines; docs/scale.md keeps them.
{ pkgs, module }:
let
  # Direct inserts through calibre's own connection (it registers the SQL
  # functions its triggers need). add_books would take ~15 min for 10000
  # because it writes a folder and an OPF per book; metadata events don't
  # need files.
  generate = pkgs.writeText "generate.py" ''
    import random, sys
    from calibre.library import db

    random.seed(1)
    api = db(sys.argv[1]).new_api
    b = api.backend
    n = int(sys.argv[2])
    col = b.execute("select id from custom_columns where label = 'kategorie'").fetchone()[0]
    cats = [f"K{a}.U{x}.T{c}" for a in range(5) for x in range(8) for c in range(5)]
    b.execute("begin")
    b.executemany("insert into authors (id, name, sort, link) values (?, ?, ?, ?)",
        [(i + 1, f"Vorname Autor{i:04d}", f"Autor{i:04d}, Vorname", "") for i in range(2000)])
    b.executemany("insert into tags (id, name) values (?, ?)",
        [(1, "gruppe-a"), (2, "gruppe-b")] + [(i + 3, f"t{i}") for i in range(50)])
    b.executemany("insert into series (id, name) values (?, ?)", [(i + 1, f"Serie {i}") for i in range(300)])
    b.executemany(f"insert into custom_column_{col} (id, value) values (?, ?)", [(i + 1, c) for i, c in enumerate(cats)])
    books, al, tl, sl, kl = [], [], [], [], []
    for i in range(1, n + 1):
        a = random.randrange(2000) + 1
        books.append((i, f"Buch {i:05d}", f"Autor{a - 1:04d}, Vorname", f"Autor{a - 1:04d}/Buch {i:05d} ({i})", (i // 300) % 20 + 1))
        al.append((i, a))
        tl.append((i, 1 if i % 2 == 0 else 2))
        tl.append((i, 3 + i % 50))
        if i % 10 == 0:
            sl.append((i, i % 300 + 1))
        kl.append((i, i % len(cats) + 1))
    b.executemany("insert into books (id, title, author_sort, path, series_index) values (?, ?, ?, ?, ?)", books)
    b.executemany("insert into books_authors_link (book, author) values (?, ?)", al)
    b.executemany("insert into books_tags_link (book, tag) values (?, ?)", tl)
    b.executemany("insert into books_series_link (book, series) values (?, ?)", sl)
    b.executemany(f"insert into books_custom_column_{col}_link (book, value) values (?, ?)", kl)
    b.execute("commit")
    print(b.execute("select count(*) from books").fetchone()[0], "books")
  '';
  rename = pkgs.writeText "rename.py" ''
    import sys
    from calibre.library import db
    api = db(sys.argv[1]).new_api
    tid = api.get_item_id("tags", "gruppe-a")
    api.rename_items("tags", {tid: "gruppe-x"})
    print("renamed")
  '';
in
pkgs.testers.runNixOSTest {
  name = "calibre-hub-scale";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ module ];
      virtualisation = {
        memorySize = 4096;
        cores = 4;
        diskSize = 4096;
      };
      environment.systemPackages = [
        pkgs.calibre
        pkgs.curl
        pkgs.jq
        pkgs.sqlite
      ];
      environment.etc = {
        "hub/service".text = "service-secret";
        "hub/login".text = "login-secret";
        "hub/key".text = "0123456789abcdef0123456789abcdef";
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
        handlers."10-log" = pkgs.writeShellScript "log" ''
          ${pkgs.jq}/bin/jq -c '[.type, .bookId, (.changes // {} | keys)]' >> /var/lib/calibre-hub/events.log
        '';
      };
      systemd.tmpfiles.rules = [ "d /srv/books/library 2775 calibre-server calibre-hub -" ];
    };

  testScript = ''
    import time

    LIB = "/srv/books/library"
    API = "http://127.0.0.1:8083"
    AUTH = "-u calibre-hub:service-secret"

    def events():
        return int(machine.succeed("if [ -f /var/lib/calibre-hub/events.log ]; then wc -l < /var/lib/calibre-hub/events.log; else echo 0; fi").strip())

    def wait_events(n, timeout):
        t0 = time.monotonic()
        machine.wait_until_succeeds(f"test -f /var/lib/calibre-hub/events.log && test $(wc -l < /var/lib/calibre-hub/events.log) -ge {n}", timeout=timeout)
        return time.monotonic() - t0

    def queued():
        return int(machine.succeed("sqlite3 -cmd '.timeout 10000' /var/lib/calibre-hub/state.sqlite 'select count(*) from events'").strip())

    def wait_until(check, n, timeout, label):
        t0 = time.monotonic()
        while check() < n:
            if time.monotonic() - t0 > timeout:
                print(machine.succeed("journalctl -u calibre-hub -o cat | grep -v 'INFO - kemal' | grep -v '^{' | tail -40"))
                print(machine.succeed("sqlite3 -cmd '.timeout 10000' /var/lib/calibre-hub/state.sqlite 'select * from meta'"))
                print(machine.succeed(f"sqlite3 -cmd '.timeout 10000' {LIB}/metadata.db 'select max(seq), count(*) from hub_changelog'"))
                raise Exception(f"{label}: {check()} of {n} after {timeout} s")
            time.sleep(2)
        return time.monotonic() - t0

    def report(name, value, unit="s"):
        print(f"SCALE {name}: {value:.1f} {unit}" if isinstance(value, float) else f"SCALE {name}: {value} {unit}")

    machine.wait_for_unit("calibre-hub.service")
    machine.wait_for_open_port(8083, timeout=120)

    with subtest("generate 10000 books"):
        machine.systemctl("stop calibre-hub.service calibre-server.service")
        t0 = time.monotonic()
        machine.succeed(f"cd /tmp && sudo -u calibre-server QT_QPA_PLATFORM=offscreen calibre-debug -e ${generate} {LIB} 10000")
        report("generate", time.monotonic() - t0)
        # first start from scratch: no hub state
        machine.succeed("rm -f /var/lib/calibre-hub/state.sqlite /var/lib/calibre-hub/events.log")

    with subtest("first start"):
        machine.systemctl("start calibre-server.service")
        machine.wait_for_open_port(8083, timeout=180)
        t0 = time.monotonic()
        machine.systemctl("start calibre-hub.service")
        machine.wait_until_succeeds("sqlite3 -cmd '.timeout 10000' /var/lib/calibre-hub/state.sqlite 'select count(*) from snapshot' | grep -qx 10000", timeout=300)
        first = time.monotonic() - t0
        report("first start (snapshot of 10000)", first)
        assert first < 60, first
        machine.sleep(5)
        assert events() == 0, events()

    with subtest("single change"):
        n = events()
        t0 = time.monotonic()
        machine.succeed(f"""curl -sf {AUTH} -H 'Content-Type: application/json' -d '{{"changes":{{"tags":["leseliste"]}},"loaded_book_ids":[42]}}' {API}/cdb/set-fields/42 >/dev/null""")
        wait_events(n + 1, 30)
        single = time.monotonic() - t0
        report("single change -> handler", single)
        assert single < 5, single

    with subtest("bulk change of 1000 books"):
        n, q = events(), queued()
        t0 = time.monotonic()
        machine.succeed(f"""seq 1001 2000 | xargs -P 8 -I{{}} curl -sf {AUTH} -H 'Content-Type: application/json' -d '{{"changes":{{"rating":8}},"loaded_book_ids":[{{}}]}}' {API}/cdb/set-fields/{{}} -o /dev/null""")
        report("bulk 1000 writes", time.monotonic() - t0)
        wait_until(queued, q + 1000, 300, "bulk detected")
        report("bulk 1000 -> all events detected", time.monotonic() - t0)
        wait_until(events, n + 1000, 600, "bulk delivered")
        bulk = time.monotonic() - t0
        report("bulk 1000 -> all events at handler", bulk)
        machine.sleep(5)
        assert events() == n + 1000, events() - n
        assert bulk < 60, bulk

    with subtest("offline rename of a tag on 5000 books"):
        machine.systemctl("stop calibre-server.service")
        # earlier subtests replaced some tags, so count instead of assuming 5000
        affected = int(machine.succeed(f"sqlite3 {LIB}/metadata.db \"select count(*) from books_tags_link l join tags t on t.id = l.tag where t.name = 'gruppe-a'\"").strip())
        report("books with the renamed tag", affected, "")
        machine.succeed(f"cd /tmp && sudo -u calibre-server QT_QPA_PLATFORM=offscreen calibre-debug -e ${rename} {LIB}")
        print(machine.succeed(f"sqlite3 {LIB}/metadata.db \"select tbl, op, count(*) from hub_changelog where seq > (select max(seq) - 6000 from hub_changelog) group by 1, 2\""))
        n, q = events(), queued()
        machine.systemctl("start calibre-server.service")
        machine.wait_for_open_port(8083, timeout=180)
        t0 = time.monotonic()
        wait_until(queued, q + affected, 240, "rename detected")
        report("rename -> all events detected", time.monotonic() - t0)
        wait_until(events, n + affected, 1800, "rename delivered")
        report("rename -> all events at handler", time.monotonic() - t0)
        machine.sleep(5)
        assert events() == n + affected, events() - n

    with subtest("reconcile without changes"):
        n = events()
        t0 = time.monotonic()
        # restart = reconcile on start, the same path as the nightly one
        machine.systemctl("restart calibre-hub.service")
        machine.wait_until_succeeds("journalctl -u calibre-hub --since -2min -o cat | grep -q 'reconciled'", timeout=120)
        line = machine.succeed("journalctl -u calibre-hub --since -2min -o cat | grep 'reconciled' | tail -1").strip()
        print(line)
        machine.sleep(5)
        assert events() == n, events() - n
        report("events after restart", events() - n, "")

    with subtest("memory"):
        mem = machine.succeed("systemctl show calibre-hub -p MemoryPeak --value").strip()
        report("hub memory peak", int(mem) // (1024 * 1024), "MiB")
        size = machine.succeed("stat -c %s /var/lib/calibre-hub/state.sqlite").strip()
        report("state.sqlite", int(size) // (1024 * 1024), "MiB")
  '';
}
