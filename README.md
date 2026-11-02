# calibre-hub

A thin layer on top of [calibre-server](https://manual.calibre-ebook.com/server.html):
its own JSON API with session login, change events with hooks, and a web UI.
calibre-server stays the only writer of the library.

Status: backend, events and handlers (Phase 2). Spike notes: [docs/spike.md](docs/spike.md). Plan: Redmine epic #8388.

## API

All `/api/*` routes need the session cookie or an API token
(`Authorization: Bearer <token>`, see `apiTokenFiles`). Unsafe methods also
need the header `X-Calibre-Hub: 1`, unless only a token is sent (a request
with a cookie always needs it). A wrong token is a 401, without falling back
to the cookie. Field names are camelCase, missing values `null`.

| Route | |
|---|---|
| `POST /api/session` `{user, password}` | login, sets `hub_session` (30 days, renewed on use); 429 after 5 failures in 15 min |
| `GET /api/session`, `DELETE /api/session` | current user, logout |
| `GET /api/books` | `q` (calibre search syntax), `kategorie` (incl. children), `tag` (repeatable), `author`, `series`, `sort` (title, author, added, modified, published, series, rating), `order` (asc, desc), `offset`, `limit` (≤ 500); returns `{total, offset, limit, books}` |
| `GET /api/books/:id` | one book incl. `comments` |
| `GET /api/books/:id/cover[?size=thumb]` | cover image |
| `GET /api/books/:id/download/:format` | book file |
| `DELETE /api/books/:id` | moves the book to calibre's trash; returns `{book}` as it was |
| `GET /api/trash` | books in calibre's trash, newest first: `[{id, title, authors, formats, deletedAt}]` (`id` is the id the book had) |
| `POST /api/trash/:id/restore` | adds the book again from the trash (metadata, files, cover); returns `{book}` with a **new** id |
| `GET /api/categories` | `kategorie` tree with counts, `tags`, `authors`, `series`, `languages` |
| `PATCH /api/books/:id`, `POST /api/books` | edit (`lastModified` for conflict detection, 409), upload (multipart) |
| `POST /api/books/bulk` `{target, changes}` | `target`: `{ids: [...]}` or `{query: {...}}` (filters as in `GET /api/books`); `changes`: `addTags`, `removeTags`, `kategorie`, `series`, `numberSeries` (with `series` and `ids` only: series index 1..n in the order of the ids); returns 202 `{jobId, total}` |
| `GET /api/jobs/:id` | `{id, status: running\|done\|failed, done, total, errors: [{bookId, error}], error?}`; jobs are kept in the state DB, a running job resumes after a restart, the last 50 finished ones stay; `error` when a job stopped early. Also finds classify runs |
| `GET /api/config` | `{fastTags, categoryColumn, classify}` for the web app |
| `GET /api/classify/status` | `{enabled, model, threshold, categories, minCategories, pending, running, lastRun}`; only `{enabled: false}` when off |
| `POST /api/classify` `{target}` | `target`: `"unsorted"` (default), `{ids: [...]}` or `{query: {...}}`; returns 202 `{jobId, total}`, 409 `{categories, minCategories}` while the tree is too small |
| `GET /api/suggestions[?status=]` | latest suggestion per book with `book`: `[{bookId, category, confidence, reason, model, at, status, book}]`; `status`: pending, auto, applied, rejected, none |
| `GET /api/suggestions/:bookId` | the book's suggestion, 404 without one |
| `POST /api/suggestions/:bookId/accept` `[{category}]` | sets the suggested category, or `category` instead (`A/B` or `A.B`); status `applied` |
| `POST /api/suggestions/:bookId/reject` | status `rejected`; the book isn't asked about again until the tree changes |
| `POST /api/suggestions/accept` `{bookIds}` | bulk accept; returns `{accepted, errors: [{bookId, error}]}` |
| `PUT /api/books/:id/cover`, `POST .../cover/from-file`, `POST .../cover/from-url` | set the cover from an image, a book file, a URL |
| `GET /api/books/:id/cover/search[?q=]` | cover candidates from Open Library and, by ISBN, DNB (no API keys) |
| `/opds`, `/get/*` | calibre's OPDS feed for reader apps, HTTP Basic with the login user |
| `GET /healthz` | no auth |

calibre-server down: 502 with a JSON body.

Trash: calibre-server moves deleted books to `<library>/.caltrash/b/<id>`
but has no command to list or restore them. The hub reads that folder and
restores by adding the book again through calibre-server (metadata from
`metadata.opf`, parsed by `calibre-debug`, so custom columns survive), which
gives it a new id. The folder stays in the trash (the hub can't write the
library); restored entries are remembered in the state db and hidden. The
module sets the library pref `expire_old_trash_after` to 100 years, so
nothing expires on its own; only emptying the trash in calibre deletes for
good. Bulk delete: `POST /api/books/bulk` with `changes: {"delete": true}`
(not combined with other changes).

## Events and handlers

calibre-server stays the only writer. Triggers in `metadata.db` (installed
by `calibre-hub-triggers` in calibre-server's preStart, a package of its own
so a hub update doesn't restart calibre-server) log every
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

## Category suggestions (local model)

`classify.enable`: a small instruct model suggests a category for books
without one, only from the existing category tree (every node of
`categoryColumn`, parents included), never a new one. The hub talks to the
[Ollama](https://ollama.com) HTTP API at `classify.endpoint` and nothing
else: title, authors, series, tags, publisher, language and the description
(HTML stripped, cut at 1200 characters) stay in the home network.

- Runs: `POST /api/classify` (the web app's "Unsortierte klassifizieren"),
  nightly at `classify.schedule` over the books without a category, and for
  every book added without one (its `added` event). Runs are jobs in the
  state DB like bulk edits, in a queue of their own; a run resumes after a
  restart.
- Answer: `/api/chat` with a JSON schema whose `category` is an enum of the
  tree's paths (`A/B`) or `""` for no fit, temperature 0. The hub checks the
  answer again: unknown categories are discarded (an error for that book),
  `confidence` is clamped to 0..1, a broken answer is asked once more.
- Suggestions at or above `classify.autoApplyThreshold` are applied to books
  without a category, together with the tag `auto-kategorie` (status
  `auto`; filter by the tag to check them). The rest wait for review
  (`pending`) under "Vorschläge" in the web app and in the book detail.
  Books that have a category (only with `{ids}`/`{query}`) are never
  changed, only suggested.
- With fewer than 2 categories nothing is suggested: create a few first
  (assign them to some books), the status says how many there are. A
  rejected or no-fit book is asked again once the tree changes.
- Model down or missing: timeouts and connection errors are retried 3 times
  with backoff, then the run stops as `failed` with `error`; nothing else
  is affected. A missing model (`404`) isn't retried.

Setting up the model (in the host's config, not this module):

```nix
services.ollama = { enable = true; host = "127.0.0.1"; };  # CPU is enough for a 3B model
```

```sh
ollama pull qwen2.5:3b   # ~2 GB, ~5-20 s per book on a CPU
```

The hub starts after `ollama.service` when both run on the same host.

## CLI

`calibre-hub cli <command>`, or `hub <command>` (the package links it), talks
to a running hub with an API token. `CALIBRE_HUB_URL` (default
`https://hub.nor.sh`); token from `CALIBRE_HUB_TOKEN`,
`CALIBRE_HUB_TOKEN_FILE` or `~/.config/calibre-hub/token`.

```sh
hub search 'title:dune or tags:sf' --sort added --order desc --limit 20
hub search --kategorie Fachbuch/Software --tag leseliste --json | jq '.books[].id'
hub show 12
hub download 12 --format pdf -o dune.pdf
hub cover 12 -o cover.jpg
hub categories kategorie
hub edit 12 --title 'Dune' --authors 'Frank Herbert' --series Dune --index 1 \
  --kategorie Roman/SF --pubdate 1965-08-01 --rating 8 --identifier isbn=9780441013593
hub edit 12 --series ''                  # empty clears
hub edit 12 --comments-file - < text.html
hub tag add 12 13 14 leseliste
hub tag rm 12 leseliste
hub upload *.epub --tag neu --kategorie Roman/Krimi
hub upload dune.pdf --add-format-to 12
hub bulk --query 'series:"=Dune"' --kategorie Roman.SF --yes
hub bulk --ids 12,13 --add-tags a,b --remove-tags c --series Dune --number-series --yes
```

Every command has `--help` and `--json` (the API's JSON; on errors
`{error, exitCode, ...}`). Exit codes: 0 ok, 1 usage or invalid input, 2 not
found, 3 conflict or duplicate, 4 not authorized, 5 server unavailable or
failed. `edit` sends the `lastModified` it just read; if the book changed in
between it writes nothing and shows read, current and wanted values (exit 3).
`upload` lists the books calibre considers duplicates (`--force` adds
anyway). `bulk` asks before changing unless `--yes` (required without a
terminal) and waits for the job, listing books that failed.

Completion: `hub completion fish | source`, `source <(hub completion bash)`;
the package installs both. A Claude Code skill for the CLI is in
[docs/skills/calibre-hub/SKILL.md](docs/skills/calibre-hub/SKILL.md)
(copy it to `~/.claude/skills/calibre-hub/`).

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
    apiTokenFiles = [ "/run/secrets/hub-token-laptop" ];  # for the CLI
    calibre.servicePasswordFile = "/run/secrets/calibre-service";
    inbox.path = "/srv/books/inbox";
    leseliste = { enable = true; target = "/srv/books/reader"; };
    classify = {
      enable = true;
      # defaults: endpoint = "http://127.0.0.1:11434"; model = "qwen2.5:3b";
      # autoApplyThreshold = 0.85; schedule = "03:45" (null: no nightly run); timeout = 300;
    };
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
| `CALIBRE_HUB_STATE_DB` | `calibre-hub.sqlite` | snapshot, event queue, bulk jobs, suggestions |
| `CALIBRE_HUB_HOST`, `CALIBRE_HUB_PORT` | `127.0.0.1`, `8084` | |
| `CALIBRE_HUB_LIBRARY` | none | library path: changelog in `metadata.db`, read-only |
| `CALIBRE_HUB_SCAN_INTERVAL` | `900` | reconcile interval when triggers are missing |
| `CALIBRE_HUB_RECONCILE_AT` | `03:30` | daily reconcile, local time |
| `CALIBRE_HUB_HANDLERS_DIR` | none | executables called per event |
| `CALIBRE_HUB_HANDLER_ATTEMPTS`, `_TIMEOUT` | `10`, `600` | |
| `CALIBRE_HUB_ALERT_COMMAND` | none | called with subject and text |
| `CALIBRE_HUB_INBOX`, `_INBOX_STABLE` | none, `120` | |
| `CALIBRE_HUB_API_TOKEN_FILES` | none | comma separated files, one API token (≥ 16 characters) each |
| `CALIBRE_HUB_CLASSIFY` | `false` | `true` turns on category suggestions (needs `CALIBRE_HUB_CATEGORY_COLUMN`) |
| `CALIBRE_HUB_CLASSIFY_ENDPOINT`, `_MODEL` | `http://127.0.0.1:11434`, `qwen2.5:3b` | Ollama API and model |
| `CALIBRE_HUB_CLASSIFY_THRESHOLD`, `_SCHEDULE`, `_TIMEOUT` | `0.85`, `03:45`, `300` | auto-apply from, nightly run (empty: none), seconds per answer |
