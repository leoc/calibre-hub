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
| `GET /api/books` | `q` (calibre search syntax), `kategorie` (incl. children), `tag` (repeatable), `author`, `series`, `sort` (title, author, added, modified, published, series, rating), `order` (asc, desc), `offset`, `limit` (≤ 500); returns `{total, offset, limit, books}`; every book has `lists` (ids of the reading lists it is in). With `list=<id>` only the books of that list, `sort` then listAdded (default, newest first), title, author or series |
| `GET /api/books/:id` | one book incl. `comments` and `lists` |
| `GET /api/lists` | the reading lists the user sees (own ones first, favorites first, by name): `[{id, name, description, owner, visibility, sync, favorite, isDefault, count, coverBookIds, createdAt, updatedAt, lastUsedAt, editable}]`; `coverBookIds`: the 4 most recently added books |
| `POST /api/lists` `{name, description?, visibility?, sync?, favorite?, isDefault?}` | creates a list (201); `visibility`: private (default), readable, editable; names are unique per owner, ignoring case (409) |
| `GET /api/lists/:id`, `PATCH /api/lists/:id`, `DELETE /api/lists/:id` | one list; change any of the fields above (one default list per owner: `isDefault: true` takes it from the other); delete returns `{list}` (owner only, 403) |
| `POST /api/lists/:id/books` `{bookIds}` or `{target}` | adds books (`target` as in bulk edits; unknown ids are left out); returns `{list, added}` with the ids that were new |
| `POST /api/lists/:id/books/remove` `{bookIds}` or `{target}` | removes books; returns `{list, removed}` |
| `PUT`, `DELETE /api/lists/:id/books/:bookId` | adds (404 for an unknown book) or removes one book; `{list, added}` / `{list, removed}` |
| `GET /api/books/:id/lists` | the lists the book is in |
| `GET /api/books/:id/cover[?size=thumb]` | cover image |
| `GET /api/books/:id/download/:format` | book file |
| `DELETE /api/books/:id` | moves the book to calibre's trash; returns `{book}` as it was |
| `GET /api/trash` | books in calibre's trash, newest first: `[{id, title, authors, formats, deletedAt}]` (`id` is the id the book had) |
| `POST /api/trash/:id/restore` | adds the book again from the trash (metadata, files, cover); returns `{book}` with a **new** id |
| `GET /api/categories` | `kategorie` tree with counts, `tags`, `authors`, `series`, `languages` |
| `PATCH /api/books/:id`, `POST /api/books` | edit (`lastModified` for conflict detection, 409), upload (multipart) |
| `POST /api/books/bulk` `{target, changes}` | `target`: `{ids: [...]}` or `{query: {...}}` (filters as in `GET /api/books`); `changes`: `addTags`, `removeTags`, `kategorie`, `series`, `numberSeries` (with `series` and `ids` only: series index 1..n in the order of the ids); returns 202 `{jobId, total}` |
| `GET /api/jobs/:id` | `{id, status: running\|done\|failed, done, total, errors: [{bookId, error}], error?}`; jobs are kept in the state DB, a running job resumes after a restart, the last 50 finished ones stay; `error` when a job stopped early. Also finds classify runs |
| `GET /api/config` | `{fastTags, categoryColumn, classify, metadata}` for the web app (`fastTags` only for older web apps; lists replace them) |
| `GET /api/classify/status` | `{enabled, model, threshold, categories, minCategories, pending, running, lastRun}`; only `{enabled: false}` when off |
| `POST /api/classify` `{target}` | `target`: `"unsorted"` (default), `{ids: [...]}` or `{query: {...}}`; returns 202 `{jobId, total}`, 409 `{categories, minCategories}` while the tree is too small |
| `GET /api/suggestions[?status=]` | latest suggestion per book with `book`: `[{bookId, category, confidence, reason, model, at, status, book}]`; `status`: pending, auto, applied, rejected, none |
| `GET /api/suggestions/:bookId` | the book's suggestion, 404 without one |
| `POST /api/suggestions/:bookId/accept` `[{category}]` | sets the suggested category, or `category` instead (`A/B` or `A.B`); status `applied` |
| `POST /api/suggestions/:bookId/reject` | status `rejected`; the book isn't asked about again until the tree changes |
| `POST /api/suggestions/accept` `{bookIds}` | bulk accept; returns `{accepted, errors: [{bookId, error}]}` |
| `GET /api/metadata/status` | `{enabled, sources, model, nightly, running, changedBooks, lastRun}`; only `{enabled: false}` when off |
| `POST /api/metadata/run` `{target}` | `target`: `"incomplete"` (default), `"all"`, `"authors"` (only the author unification), `{ids: [...]}` or `{query: {...}}`; returns 202 `{jobId, total}` (incomplete/all/authors end with the author pass, one more step in `total`) |
| `GET /api/metadata/changes` | `bookId`, `since` (ISO 8601), `reverted` (true, false), `limit` (≤ 5000, default 500); returns `{changes: [{id, bookId, field, old, new, source, jobId, at, revertedAt}], books}`, newest first |
| `POST /api/metadata/changes/:id/revert` | sets the old value again; 409 when the field changed since (or the change is reverted already); returns `{change, book}` |
| `POST /api/metadata/changes/revert` `{bookIds?, changeIds?}` | bulk revert (by book: all its active changes); returns `{reverted, errors: [{changeId, bookId, error}]}` |
| `GET /api/books/:id/metadata/candidates[?q=]` | for "Metadaten holen": `{candidates: [{source, score, sure, url, fields: {title, authors, isbn, publisher, pubdate, languages, comments, series, seriesIndex, coverUrl}}]}`, best first; applied through `PATCH /api/books/:id` and `.../cover/from-url` |
| `PUT /api/books/:id/cover`, `POST .../cover/from-file`, `POST .../cover/from-url` | set the cover from an image, a book file, a URL |
| `GET /api/books/:id/cover/search[?q=]` | cover candidates from Open Library and, by ISBN, DNB (no API keys) |
| `/opds`, `/get/*` | calibre's OPDS feed for reader apps, HTTP Basic with the login user |
| `/opds/lists`, `/opds/lists/:id[?offset=]` | the reading lists as OPDS catalogs (Basic auth like `/opds`): a navigation feed of the lists the user sees, and per list an acquisition feed, most recently added first, 100 books per page (`next`/`previous` links); files and covers link to `/get/*` |
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
Reading lists add `{"type": "list", "action": "created|updated|deleted|added|removed",
"bookId": 0, "listId": 3, "list": {...}, "previous": {...}, "bookIds": [...], "at": ...}`
(`previous`: the list before an update; `bookIds`: the books added or
removed, or the books of a deleted list).
Every executable in the handlers directory gets each event on stdin, in
order per handler. Exit 0 = done, otherwise retry with backoff (10 s up to
1 h); after `handlerAttempts` the delivery is parked and `alertCommand` is
called with subject and text.

Bundled handler `calibre-hub handler leseliste` (`leseliste.enable`):
mirrors every reading list with `sync` into a folder of its own below
`leseliste.target` (`<target>/<list name>/Author - Series NN - Title.epub`;
epub, else pdf, else converted). A book in two synced lists is in both
folders; a book that leaves a list (or is deleted) loses its file, a
renamed list renames its folder, a list no longer synced loses its folder.
It reads the lists from the state DB, read-only.

## Reading lists

Lists like playlists, kept in the hub's state DB (calibre Desktop doesn't
see them): name, description, owner, visibility (private, readable,
editable; matters once there is more than one user), sync to the reader,
favorite (shown in the sidebar), default list (the bookmark on the cover)
and the books with the time they were added. A deleted book leaves its
lists and goes back into them when it is restored from the trash.

Migration: on the first start the books with the tag `leseliste.tag`
(default `leseliste`) become the list "Leseliste", synced, favorite and
default list. The tag stays on the books but is no longer read; the list is
the source of truth from then on.

Visibility is set in the web app ("Liste bearbeiten") and stored per list;
with a single login user it changes nothing yet. Reader apps can add
`https://<hub>/opds/lists` as a catalog of their own. The reader folder changes from category
subfolders to `<target>/Leseliste/`.

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

## Metadata cleanup

`metadata.enable`: completes and cleans up the metadata of the whole
library, so the category suggestions work on clean titles, authors and
ISBNs. Everything is applied automatically; every changed book gets the tag
`auto-metadaten`, and every field change is logged in the state DB with old
and new value and can be reverted alone or per book ("Metadaten" in the web
app, or the API). Categories and other tags are never touched.

Per book (`src/calibre_hub/metadata.cr`, rules in `meta_rules.cr`, sources
in `meta_sources.cr`):

1. File: the EPUB's OPF (title, authors, ISBN, publisher, date, language,
   description, series) and ISBNs in the text of its first and last pages;
   a PDF's info dict and first pages (`pdfinfo`/`pdftotext`). The file is
   downloaded through calibre-server.
2. Rules: download-site junk (`(z-lib.org)`, `[libgen.li]`, hashes,
   extensions, underscores), "Autor - Titel" or "Titel - Autor" in the
   title, "Author - Series 03 - Title", "Unbekannt"/"Unknown" as author,
   "Last, First", several authors in one field, all caps or all lower case,
   a broken author sort (one that shares no name with the authors). When
   the rules can't tell author from title (`Wolken - Atlas`) and
   `metadata.useModel` is on, the classify model is asked, with title and
   authors only; its answer is used only if every word in it was in the
   input.
3. Sources, in `metadata.sources` order: ISBNs first (calibre's, the
   OPF's, the text's) at Open Library (books API) and the DNB (SRU,
   MARC21); title and author search only when no ISBN gave a sure match.
4. Score 0..1: title 60 %, authors 30 %, language and year 10 %. A match
   by ISBN is **sure** when the ISBN is in calibre or the OPF, or when the
   result also agrees with the book (score ≥ 0.5; an ISBN on an ad page
   doesn't). A text match from 0.75 is **accepted**.
5. Merge per field: rules' title and authors, then the file, then the
   candidates, best first. Missing fields are filled from an accepted
   candidate (ISBN, publisher and date only from one edition, not a work
   with many); an existing value is replaced only when it is broken, by a
   sure match that clearly differs (publisher, year, language, a
   completely different title), or by the same value spelled better
   (case, accents, "Le Guin" for "LeGuin", "J. R. R. Tolkien" for
   "Tolkien"). Descriptions are only filled; a cover only for books
   without one.
6. One `PATCH` with `lastModified`; a book changed meanwhile is tried once
   more, then on the next run.

Author unification: a library-wide pass groups names by a key without
case, accents, punctuation, spaces and "Last, First" and renames every
variant to the best form: proper case, then confirmed by Open Library/DNB,
then the most books. Logged and revertible like the rest.

Runs are jobs in a queue of their own, resumed after a restart:
`POST /api/metadata/run`, nightly at `metadata.nightly` (off by default;
incomplete books plus the author pass) and for every added book. A new
book is classified only after its metadata run is done or failed (at most
30 minutes later). "incomplete": books missing ISBN, publisher, date,
language or description, or with messy names; books checked in the last 30
days without a failed source are skipped. Requests to a source are spaced
by `metadata.requestInterval` ms.

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
hub tag add 12 13 14 sf
hub tag rm 12 sf
hub list ls                              # reading lists; a list by id or name
hub list show Leseliste --sort title
hub list create Urlaub --description 'Für den Strand' --sync --favorite --visibility private
hub list add Leseliste 12 13
hub list rm leseliste 12
hub list delete Urlaub --yes
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
    metadata = {
      enable = true;
      # defaults: sources = [ "file" "openlibrary" "dnb" ]; nightly = null; useModel = classify.enable;
      # openLibraryUrl, openLibraryCoversUrl, dnbUrl (the public services); requestInterval = 1000;
      nightly = "03:15";
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
| `CALIBRE_HUB_STATE_DB` | `calibre-hub.sqlite` | snapshot, event queue, bulk jobs, suggestions, reading lists |
| `CALIBRE_HUB_HOST`, `CALIBRE_HUB_PORT` | `127.0.0.1`, `8084` | |
| `CALIBRE_HUB_LIBRARY` | none | library path: changelog in `metadata.db`, read-only |
| `CALIBRE_HUB_SCAN_INTERVAL` | `900` | reconcile interval when triggers are missing |
| `CALIBRE_HUB_RECONCILE_AT` | `03:30` | daily reconcile, local time |
| `CALIBRE_HUB_HANDLERS_DIR` | none | executables called per event |
| `CALIBRE_HUB_HANDLER_ATTEMPTS`, `_TIMEOUT` | `10`, `600` | |
| `CALIBRE_HUB_ALERT_COMMAND` | none | called with subject and text |
| `CALIBRE_HUB_INBOX`, `_INBOX_STABLE` | none, `120` | |
| `CALIBRE_HUB_LIST_MIGRATE_TAG` | `leseliste` | books with this tag become the list "Leseliste" on the first start |
| `CALIBRE_HUB_API_TOKEN_FILES` | none | comma separated files, one API token (≥ 16 characters) each |
| `CALIBRE_HUB_CLASSIFY` | `false` | `true` turns on category suggestions (needs `CALIBRE_HUB_CATEGORY_COLUMN`) |
| `CALIBRE_HUB_CLASSIFY_ENDPOINT`, `_MODEL` | `http://127.0.0.1:11434`, `qwen2.5:3b` | Ollama API and model |
| `CALIBRE_HUB_CLASSIFY_THRESHOLD`, `_SCHEDULE`, `_TIMEOUT` | `0.85`, `03:45`, `300` | auto-apply from, nightly run (empty: none), seconds per answer |
| `CALIBRE_HUB_METADATA` | `false` | `true` turns on the metadata cleanup |
| `CALIBRE_HUB_METADATA_SOURCES`, `_NIGHTLY`, `_MODEL`, `_INTERVAL` | `file,openlibrary,dnb`, none, `false`, `1000` | sources, nightly run, clean names with the classify model, ms between requests |
| `CALIBRE_HUB_OPENLIBRARY_URL`, `_OPENLIBRARY_COVERS_URL`, `_DNB_URL` | the public services | base URLs (stubs in the VM test) |
