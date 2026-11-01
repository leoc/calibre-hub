# calibre-hub

A thin layer on top of [calibre-server](https://manual.calibre-ebook.com/server.html):
its own JSON API with session login, change events with hooks, and a web UI.
calibre-server stays the only writer of the library.

Status: backend (Phase 1). Spike notes: [docs/spike.md](docs/spike.md). Plan: Redmine epic #8388.

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
  CALIBRE_HUB_WATCH=/tmp/hub-testlib/library/metadata.db
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
| `CALIBRE_HUB_WATCH` | none | `metadata.db`; scan when it changes |
| `CALIBRE_HUB_SCAN_INTERVAL` | `900` | seconds between full scans |
