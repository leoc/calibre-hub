# calibre-hub

A thin layer on top of [calibre-server](https://manual.calibre-ebook.com/server.html):
its own JSON API with session login, change events with hooks, and a web UI.
calibre-server stays the only writer of the library.

Status: backend, events and handlers (Phase 2). Spike notes: [docs/spike.md](docs/spike.md). Plan: Redmine epic #8388.

## API

All `/api/*` routes need the session cookie; unsafe methods also need the
header `X-Calibre-Hub: 1`. Field names are camelCase, missing values `null`.

| Route | |
|---|---|
| `POST /api/session` `{user, password}` | login, sets `hub_session` (30 days, renewed on use); 429 after 5 failures in 15 min |
| `GET /api/session`, `DELETE /api/session` | current user, logout |
| `GET /api/books` | `q` (calibre search syntax), `kategorie` (incl. children), `tag` (repeatable), `author`, `series`, `sort` (title, author, added, modified, published, series, rating), `order` (asc, desc), `offset`, `limit` (≤ 500); returns `{total, offset, limit, books}` |
| `GET /api/books/:id` | one book incl. `comments` |
| `GET /api/books/:id/cover[?size=thumb]` | cover image |
| `GET /api/books/:id/download/:format` | book file |
| `GET /api/categories` | `kategorie` tree with counts, `tags`, `authors`, `series`, `languages` |
| `/opds`, `/get/*` | calibre's OPDS feed for reader apps, HTTP Basic with the login user |
| `GET /healthz` | no auth |

calibre-server down: 502 with a JSON body.

## Events and handlers

calibre-server stays the only writer. Triggers in `metadata.db` (installed
by `calibre-hub install-triggers` in calibre-server's preStart) log every
change to a book, its links and renamed tags/authors/series into
`hub_changelog`; the hub only reads it. Writes the hub makes itself (inbox)
emit events right away. A cheap reconcile (`id`, `last_modified`) runs on
start and daily at `reconcileAt`.

Events: `{"type": "added|changed|deleted", "bookId": 1, "changes":
{"tags": [[old], [new]], "#kategorie": [...]}, "book": {...}, "at": ...}`.
Every executable in the handlers directory gets each event on stdin, in
order per handler. Exit 0 = done, otherwise retry with backoff (10 s up to
1 h); after `handlerAttempts` the delivery is parked and `alertCommand` is
called with subject and text.

Bundled handler `calibre-hub handler leseliste` (`leseliste.enable`):
mirrors books with a tag into a folder (epub, else pdf, else converted),
subfolders from the category column, files named `Author - Series NN - Title`.

Inbox (`inbox.path`): files unchanged for `inbox.stableSeconds` are added
through calibre-server; `A/B/x.epub` gets category `A.B` and tags `A`, `B`,
tags embedded in the file are dropped. Originals move to `_imported/<date>/`
or `_duplicates/<date>/`, after 3 failures to `_failed/<date>/`. Folders the
hub can't write are skipped.

Scale: see [docs/scale.md](docs/scale.md) (`nix build .#scale-test -L`).

## NixOS module

```nix
{
  inputs.calibre-hub.url = "git+ssh://git@git.velalu.qa:53639/arthur/calibre-hub.git";
  # nixosConfigurations.<host>.modules = [ calibre-hub.nixosModules.default ];
  services.calibre-hub = {
    enable = true;
    library = "/srv/books/calibre";
    customColumns.kategorie = { name = "Kategorie"; hierarchical = true; };
    categoryColumn = "kategorie";
    login.passwordFile = "/run/secrets/login";
    sessionKeyFile = "/run/secrets/session-key";
    calibre.servicePasswordFile = "/run/secrets/calibre-service";
    inbox.path = "/srv/books/inbox";
    leseliste = { enable = true; target = "/srv/books/reader"; };
    alertCommand = "/run/current-system/sw/bin/notify-admin";
    handlers."20-log" = pkgs.writeShellScript "log" "cat >> /var/lib/calibre-hub/events.log";
  };
}
```

With `calibre.manage` (default) the module configures calibre-server on
127.0.0.1 with Basic auth and prepares library, columns and users before each
start. Secrets are passed as systemd credentials, so they can stay root-owned.
`nix flake check` runs the specs and a NixOS VM test.

## Development

```sh
nix develop
dev/testlib.sh /tmp/hub-testlib &      # test library + calibre-server on :18083
printf %s hub > /tmp/hub-pw
export CALIBRE_HUB_CALIBRE_URL=http://127.0.0.1:18083 CALIBRE_HUB_CALIBRE_USER=hub \
  CALIBRE_HUB_CALIBRE_PASSWORD_FILE=/tmp/hub-pw CALIBRE_HUB_CUSTOM_COLUMNS=kategorie \
  CALIBRE_HUB_LIBRARY=/tmp/hub-testlib/library CALIBRE_HUB_LIBRARY_ID=library
shards build && bin/calibre-hub serve   # API on 127.0.0.1:8084
crystal spec
nix build                               # package
```

After changing dependencies: `shards install && crystal2nix`.

## Configuration (environment)

| Variable | Default | |
|---|---|---|
| `CALIBRE_HUB_CALIBRE_URL` | `http://127.0.0.1:8083` | calibre-server |
| `CALIBRE_HUB_CALIBRE_USER` | `calibre-hub` | service user in calibre-server |
| `CALIBRE_HUB_CALIBRE_PASSWORD_FILE` | required | without trailing newline |
| `CALIBRE_HUB_LIBRARY_ID` | server default | |
| `CALIBRE_HUB_CUSTOM_COLUMNS` | none | comma separated, e.g. `kategorie` |
| `CALIBRE_HUB_STATE_DB` | `calibre-hub.sqlite` | snapshot and event queue |
| `CALIBRE_HUB_HOST`, `CALIBRE_HUB_PORT` | `127.0.0.1`, `8084` | |
| `CALIBRE_HUB_LIBRARY` | none | library path: changelog in `metadata.db`, read-only |
| `CALIBRE_HUB_SCAN_INTERVAL` | `900` | reconcile interval when triggers are missing |
| `CALIBRE_HUB_RECONCILE_AT` | `03:30` | daily reconcile, local time |
| `CALIBRE_HUB_HANDLERS_DIR` | none | executables called per event |
| `CALIBRE_HUB_HANDLER_ATTEMPTS`, `_TIMEOUT` | `10`, `600` | |
| `CALIBRE_HUB_ALERT_COMMAND` | none | called with subject and text |
| `CALIBRE_HUB_INBOX`, `_INBOX_STABLE` | none, `120` | |
