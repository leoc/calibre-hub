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

Users: the login user (`login.user`, an admin, with the tokens of
`apiTokenFiles`) and the further `users` of the module, each `admin` or
`reader`, with their own password file and tokens. Lists, reading progress
and reader settings are per user, the library is shared. A reader reads and
downloads everything but writes only their own lists (not synced to the
reader folder), progress and reader settings; every other unsafe request,
also of routes added later, is a 403 for readers. The users are kept in the
state DB (`users`); one removed from the configuration keeps their data but
can't log in.

| Route | |
|---|---|
| `POST /api/session` `{user, password}` | login, sets `hub_session` (30 days, renewed on use; a new password ends the user's sessions); 429 after 5 failures in 15 min |
| `GET /api/session`, `DELETE /api/session` | current user `{user, role}` (role `admin` or `reader`), logout |
| `GET /api/books` | `q` (calibre search syntax), `kategorie` (incl. children), `tag` (repeatable), `author`, `series`, `sort` (title, author, added, modified, published, series, rating), `order` (asc, desc), `offset`, `limit` (≤ 500); returns `{total, offset, limit, books}`; every book has `lists` (ids of the reading lists it is in). With `list=<id>` only the books of that list and its sublists (`direct=1`: only its own), `sort` then listAdded (default, newest first), title, author or series; `listPath=Urlaub` (`listOwner`, default the user) does the same for a level that may have no list of its own (404 when nothing is below it) |
| `GET /api/books/:id` | one book incl. `comments` and `lists` |
| `GET /api/lists` | the reading lists the user sees (own ones first, favorites first, by name): `[{id, name, description, owner, visibility, sync, favorite, isDefault, count, totalCount, parent, leaf, coverBookIds, createdAt, updatedAt, lastUsedAt, editable, rule, query, queryError}]`; `coverBookIds`: the 4 most recently added books; nested lists: `parent` the path above (`"Urlaub"` for `"Urlaub/2026"`, null at the top), `leaf` the last level, `totalCount` the distinct books incl. the sublists the user sees; `rule`/`query`: a magic shelf's rule and its calibre search (null for a list with books of its own), `queryError` when that search failed (count 0) |
| `POST /api/lists` `{name, description?, visibility?, sync?, favorite?, isDefault?, rule?}` | creates a list (201), with `rule` a magic shelf (see below); `visibility`: private (default), readable, editable; names are unique per owner, ignoring case (409); a name is a path, `"Urlaub/2026"` (levels trimmed, no empty level: 400 for `a//b`, `/a`, `a/`; existing levels keep their spelling) |
| `GET /api/lists/:id`, `PATCH /api/lists/:id`, `DELETE /api/lists/:id` | one list; change any of the fields above (one default list per owner: `isDefault: true` takes it from the other); a new name renames the sublists along (one `updated` event each; 409 when one of the new names is taken, 400 below itself); delete returns `{list}` (owner only, 403) and leaves the sublists |
| `POST /api/lists/:id/books` `{bookIds}` or `{target}` | adds books (`target` as in bulk edits; unknown ids are left out); returns `{list, added}` with the ids that were new; 400 for a magic shelf (also removing) |
| `POST /api/lists/:id/books/remove` `{bookIds}` or `{target}` | removes books; returns `{list, removed}` |
| `PUT`, `DELETE /api/lists/:id/books/:bookId` | adds (404 for an unknown book) or removes one book; `{list, added}` / `{list, removed}` |
| `GET /api/books/:id/lists` | the lists the book is in |
| `GET /api/books/:id/cover[?size=thumb]` | cover image |
| `GET /api/books/:id/download/:format` | book file; `Range` requests are passed to calibre-server (`Accept-Ranges`, `Content-Range` come back) |
| `GET /api/books/:id/progress` | reading progress of the user: `{latest, devices: [...]}`, every device's last position, newest first; an entry is `{bookId, device, deviceName, format, position, fraction, source, updatedAt}`, `latest` is the newest (null when the book was never opened) |
| `PUT /api/books/:id/progress` `{format, position, fraction, device, deviceName?, source?, age?}` | stores the device's position (replaces its last one unless that is newer; the time is the hub's, minus `age` in ms for a position read offline and sent later, at most 30 days): `position` depends on the format (EPUB/MOBI/AZW3/CBZ: CFI from foliate-js, PDF: page number), `fraction` 0..1, `device` an id per browser/device, `deviceName` shown in "Auf … weiterlesen?", `source` web (default) or koreader |
| `GET /api/progress` | the newest position per book (progress bars on the covers): `[{bookId, fraction, format, updatedAt}]` |
| `GET /api/reader/settings` | the user's reader settings, all fields (defaults for unset ones): `{fontFamily, fontSize, lineHeight, justify, hyphenate, margin, maxWidth, columns, flow, animated, theme, override}` |
| `PUT /api/reader/settings` `{field: value, ...}` | changes the given fields, returns all; `fontFamily` original, serif, sans, literata, atkinson, source-serif or inter; `fontSize` 50..300 (%); `lineHeight` 1.0..2.5; `margin` 0..20 (% per side); `maxWidth` 400..2000 (px per column); `columns` auto, 1 or 2; `flow` paginated or scrolled; `theme` light, sepia, dark or eink; `justify`, `hyphenate`, `animated`, `override` true/false; unknown fields or bad values: 400 `{error, field}` |
| `DELETE /api/books/:id` | moves the book to calibre's trash; returns `{book}` as it was |
| `GET /api/trash` | books in calibre's trash, newest first: `[{id, title, authors, formats, deletedAt}]` (`id` is the id the book had) |
| `POST /api/trash/:id/restore` | adds the book again from the trash (metadata, files, cover); returns `{book}` with a **new** id |
| `GET /api/duplicates[?threshold=]` | groups of books that look like the same book: `{threshold, groups: [{id, bookIds, keepId, sure, score, reasons: [{kind, bookIds, detail}], books: [{book, hasCover, broken, files: [{format, size, tiny}]}]}]}`; `kind`: isbn, file, title, broken; `keepId` the suggested book to keep; `threshold` 0.5..1 (default `duplicates.threshold`) |
| `POST /api/duplicates/merge` `{keepId, bookIds, dryRun?, lastModified?}` | merges `bookIds` into `keepId` (see Duplicates); `dryRun: true` returns `{plan: {keepId, otherIds, fields: [{field, old, new}], formats: [{format, from, replace}], coverFrom, lists, progress, trash}}`, else `{merge, book}`; 409 when the keeper changed since `lastModified` |
| `GET /api/duplicates/merges` | the last merges, newest first: `[{id, keepId, otherIds, status: running\|done\|failed\|undone, at, undoneAt, error, fields, formats, coverFrom, listItems, progress, trashed, restored, errors}]` |
| `POST /api/duplicates/merges/:id/undo` | undoes a merge: `{merge, books}` (the keeper and the books back from the trash, with new ids); 409 when undone already |
| `POST /api/duplicates/ignore` `{bookIds}`, `POST /api/duplicates/ignore/remove` `{bookIds}` | marks every pair of the books as no duplicates (or not any more): `{ignored}` / `{removed}` |
| `GET /api/categories` | `kategorie` tree with counts, `tags`, `authors`, `series`, `languages` |
| `PATCH /api/books/:id`, `POST /api/books` | edit (`lastModified` for conflict detection, 409), upload (multipart; a new book the duplicate detection pairs with others gets `possibleDuplicates: [book]`) |
| `POST /api/books/bulk` `{target, changes}` | `target`: `{ids: [...]}` or `{query: {...}, expect?, all?}` (filters as in `GET /api/books`: `q`, `kategorie`, `tag`, `author`, `series`, `list`, `listPath`, `listOwner`, `direct`; any other key is a 400, and so is a query without any filter unless `all: true`; with `expect` the number of books the query matches must be that one, else 409 `{expected, found}`; deleting by query requires `expect`; the same holds for every `{query}` target below); `changes`: `addTags`, `removeTags`, `kategorie`, `series`, `numberSeries` (with `series` and `ids` only: series index 1..n in the order of the ids), `authors`, `publisher`, `languages`, `rating`, `pubdate`, `pubYear` (the year, month and day stay); returns 202 `{jobId, total}` |
| `POST /api/jobs/:id/undo` | puts back what a finished bulk field change overwrote (each book's own values, remembered per book while the job ran) as a new job, only where a field still has the value the job set (a field changed since stays and shows in the undo job's `errors` as "changed since, left as it is: <fields>"; tags go back as a difference, so tags added since stay); once per job, 409 for a running job, a delete or one undone already; returns 202 `{jobId, total}` |
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
| `GET /api/embed/status` | `{enabled, delay, pending}`: books waiting for their files to be rewritten; only `{enabled: false}` when off |
| `GET /api/convert/status` | `{enabled, target, ignore, targets, running, lastRun}` (`enabled`: added books are converted) |
| `POST /api/convert` `{target?, books?}` | converts every book (or those of `books`, `{ids}` or `{query}` as in bulk edits) without `target` (default the configured one; EPUB, AZW3, MOBI, PDF, DOCX, FB2) that has a format not in `ignore`; returns 202 `{jobId, total}`, progress in `GET /api/jobs/:id` |
| `POST /api/epub-fix` `{dryRun?, target?}` | runs the EPUB fixer over every book with an EPUB, or `target` (`{ids}` or `{query}` as in bulk edits); `dryRun` defaults to `true` (only checks); returns 202 `{jobId, total, dryRun}`, progress in `GET /api/jobs/:id` |
| `GET /api/epub-fix/status` | `{onImport, keepOriginal, running, lastRun}`; `lastRun` is the job with `dryRun`, `from` (library, selection, added), `booksWithFixes`, `booksWithProblems`, `booksFixed` and counts per fix and problem (`fixes`, `problems`) |
| `GET /api/epub-fix/jobs/:id` | the same for one run plus `results`: `[{bookId, title, applied, fixes: [{code, file, detail}], problems: [...]}]` (books with something to report, at most 500) |
| `GET /api/import` | backlog import: `{enabled, roots, running, scanning, hooksPaused, phase, backlog, followup, runs: [...], cleanups: [...]}` (the last 10 runs and cleanups); `phase`: scan, check, import, followup or null; `backlog`: `{imported, formatAdded, duplicates, open: {books, formats, duplicates, failed}, total, basis, etaSeconds}` (see Backlog import); `followup`: `{paused, total, queues: {metadata, classify, convert, embed}}`, the books those hooks still have to work off; only `{enabled: false, cleanups}` without `backlogImport.roots` |
| `POST /api/import` `{path \| paths: [...], dryRun?, limit?}` | queues a run of the folders (absolute, or relative to the first root; must be in a root, 400) and returns at once: 202 with the run `{id, path, paths, dryRun, limit, status: "scanning", jobId, scan, summary: null}`; the job scans and plans (`scan: {files, units, planned}` while it runs), a dry run (default) ends `planned`, an import goes on with a unit per book (`GET /api/jobs/:id`); `limit`: at most that many books that add a book or formats, in scan order; 409 while another import runs |
| `GET /api/import/runs/:id`, `GET /api/import/runs/:id/report` | a run (status: scanning, planned, running, done, failed, gone; `phase`: scan, check, import, else the status; `current`: the folder or book it is at; `startedAt`, `scannedAt`, `finishedAt`, `elapsedSeconds`; `filesPerSecond` while scanning, `booksPerMinute`; `etaSeconds` while checking and importing; `done`/`total`, `summary` once scanned, `results` per status: pending, imported, formatAdded, duplicate, failed, deferred; `failures`: the first 20 failed books `{path, detail}`); the report adds every book (`units`: files, plan, status, `bookId`, `match`, `detail`) and every skipped file (`skipped: [{path, reason}]`) |
| `POST /api/import/cleanup` `{since?, minId?, maxId?, dryRun?}` | takes back the folder category and tags the inbox set on the books it added (see Backlog import); dry run (default): `{total, entries}`, else 202 with the cleanup `{id, entries, job}` |
| `GET /api/import/cleanups/:id`, `POST /api/import/cleanups/:id/undo` `{dryRun?}` | a cleanup with its backup; undo puts category and tags back (dry run by default, else 202 with `undoJob`) |
| `/opds`, `/get/*` | calibre's OPDS feed for reader apps, HTTP Basic with the login user |
| `/opds`, `/get/*` | calibre's OPDS feed for reader apps, HTTP Basic with any hub user |
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

## Duplicates

`GET /api/duplicates` (the web app's "Duplikate") looks over the whole
library on request (`src/calibre_hub/dedup.cr`, rules without calibre; `duplicates.cr` around it).
Two books are a pair when they share

- **isbn**: an ISBN, from the identifiers or in a download-site title
  (Anna's Archive's `Title -- Author -- … -- 978… -- …`, whose author also
  counts),
- **file**: a format file with the same size and MD5 (sizes from
  `metadata.db`, read-only; a checksum only for files whose format and size
  another file has too, cached),
- **title**: an author (normalized like the author unification: case,
  accents, "Last, First") and a title at least `duplicates.threshold`
  alike: the same title ignoring case and punctuation 1.0, a subtitle on
  one side only 0.95, one title the start of the other (3 words or more)
  0.9, else the token overlap of the main titles (of the whole titles when
  both have a subtitle). A book without a known author ("Unknown") needs
  0.9 at least and is compared with the books sharing its first title
  word. Volume 1 and 2 ("Band 1", "Vol. II") or two numbers of one series
  never pair.

A **broken** book (no files, or only files below 2 KiB: a download
leftover) pairs with a good copy from 0.6 and gets the reason `broken`.
Pairs join into groups; a group is `sure` with an ISBN, a file or the
same title. Pairs marked "Keine Duplikate" (`duplicate_ignored`) stay out.

The suggested book to keep: not broken, the most complete metadata
(known authors, ISBN, publisher, date, language, description, series,
cover, tags other than `auto-metadaten`, category, a clean title), the
best format (EPUB, KEPUB, AZW3, MOBI, … PDF …), the most formats, the
oldest on a tie.

Merging (`POST /api/duplicates/merge`, through calibre-server like every
write):

1. Empty fields of the keeper are filled from the others (the best first):
   authors only instead of unknown ones, series with its number,
   publisher, date, languages, description, rating, category;
   identifiers and tags are joined (the keeper's value wins, the
   `auto-metadaten` marker stays out). One `PATCH` with `lastModified`.
2. Formats the keeper lacks come from the others (from the library
   folder, else downloaded); a tiny file of its own is replaced (calibre
   moves the old file to its trash). Tiny files of the others are not
   moved.
3. The cover of another book when the keeper has none.
4. Reading list memberships (any owner) and reading positions (per device,
   the newer wins) move to the keeper in the state DB.
5. The others go to calibre's trash (`.caltrash`), never deleted.

Every step is logged in `duplicate_merges`, so a merge can be undone
(also a failed one, as far as it got): the others come back from the trash
(new ids, their lists and positions with them), the moved formats go to
calibre's trash again, the cover goes, the filled fields are set back where
nobody changed them since (tags and identifiers lose only what the merge
added); what stays is listed in `errors`.

Uploads (`POST /api/books`) answer with `possibleDuplicates`, the inbox
logs `inbox: #42 looks like #7 (see Duplikate)`; both use the same
detection. calibre's own exact check (title and author) still refuses a
copy unless forced, the inbox still moves those to `_duplicates/`.

## Reading in the browser

`/read/:id[?format=]` in the web app reads EPUB, KEPUB, MOBI/AZW3, FB2, CBZ
and PDF with [foliate-js](https://github.com/johnfactotum/foliate-js)
(vendored, `frontend/vendor/foliate-js`). The file comes through
`/api/books/:id/download/:format`. The position is saved per user, book and
device (`reading_progress` in the state DB, `PUT /api/books/:id/progress`);
the newest one wins. A book opens where this device stopped; when another
device saved a newer position since, the reader asks "Auf <Gerät> bei 71 % –
dort weiterlesen?". The table keeps a `source` per row so KOReader's sync
positions can live next to the web reader's later.

Books can be made available offline in the web app (detail or reader). The
file then lives in the browser's Cache Storage; a service worker
(`frontend/src/service-worker.js`) keeps the app itself offline, but never
caches `/api/`. Positions read offline wait in the browser and are sent on
reconnect with their `age`, so they don't win over what another device read
in the meantime.

The reader's settings (font, size, line height, justification, hyphenation,
margins, column width, columns, paginated or scrolled, page-turn animation,
colors, "Buchstil überschreiben") are per user and the same on every device
(`reader_settings` in the state DB, `GET/PUT /api/reader/settings`). Fonts
besides the book's and the system's serif/sans come with the web app
(Literata, Atkinson Hyperlegible, Source Serif 4, Inter; SIL OFL, from
@fontsource) and load only when chosen, no CDN. Absolute font sizes in a
book's CSS (`font-size: small`, `12pt`, `1rem`) are rewritten while loading
so they follow the reader's font size.

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
renamed list renames its folder, a list no longer synced loses its files
(and its folder once nothing else is in it).
Nested lists nest their folders (`<target>/Urlaub/2026/…`); a synced list
takes its sublists along, unsynced ones too.
It reads the lists from the state DB, read-only. It only ever removes files
it copied itself, recorded in `<target>/.calibre-hub-files`: what the
e-reader keeps next to a book (KOReader's `<book>.sdr/` with progress,
highlights and notes), files put there by hand and anything from before the
record existed stay where they are, also when their book leaves the list.

## Book files

Embedding (`embed.enable`, on by default): after an edit of title, authors,
author sort, series, tags, description, identifiers, languages, publisher,
date, rating or cover (and when a format is added) the hub has
calibre-server write the metadata and cover into the book's files (cdb
`embed_metadata`), so a copy on a reader shows what calibre shows. Only
formats calibre has a metadata writer for (EPUB, KEPUB, AZW3, MOBI, PDF,
DOCX, FB2, RTF, ODT, ...); others are skipped. The queue is in the state DB
(`embed_queue`): every edit moves the book's due time to `embed.delay`
seconds later, so several quick edits end in one rewrite; failures are
retried with backoff. A book is not rewritten again for the same metadata
unless the cover or its formats changed. calibre embeds nothing into a book
without a cover; for those the formats calibre-server embeds into on
download (EPUB, AZW3, MOBI, PDF) are downloaded and added back. Covers set
outside the hub (calibre's own web UI) don't show in events and are
embedded with the next edit.

After a rewrite the hub queues a `changed` event with `formats` (the same
list on both sides: the files changed), so the reading list copies the file
again. Rewriting changes the file's checksum and so the document id
KOReader syncs reading positions under (KOSync partial MD5); the checksum a
file had before each rewrite is kept in `file_checksums` (book, format,
partial MD5, size, time; the oldest per book and format is the original).

Conversion (`convert.enable`, off by default): added books (inbox, upload,
calibre) without the `convert.target` format are converted with
`ebook-convert` from a copy downloaded through calibre-server, and the new
file is added; the original stays. Sources in `convert.ignore` (PDF, CBZ,
CBR) are never converted from. `POST /api/convert` (the web app's
"Bestand nach EPUB konvertieren" on the Metadaten page) does the same for
the whole library, also while automatic conversion is off. Conversions are
jobs in a queue of their own, resumed after a restart.

EPUB fixer (like Calibre-Web-Automated's, after kindle-epub-fix): repairs
what keeps an EPUB from opening on a reader or from being accepted by Send
to Kindle. Conservative: only these, as small text edits on the files that
need them, every other entry copied byte for byte; running it again finds
nothing.

- `mimetype`: missing, wrong, compressed or not the first entry
- `xml-declaration`: a content document without one gets the UTF-8 declaration
- `encoding`: a declared (or meta charset) encoding that doesn't match
  UTF-8 content is corrected; a file entirely in a legacy encoding (as
  declared, else Windows-1252) is converted to UTF-8. Mixed files (UTF-8
  with stray Latin-1 bytes) are only reported
- `language`: a missing, empty or meaningless `dc:language` (`und`, `zxx`,
  `mul`) becomes the book's calibre language (two letters where there are
  two); without one in calibre it is only reported
- `spine-toc`: the spine's `toc` points at the NCX (added when missing, fixed
  when it names no manifest item)
- `cover-meta`: `<meta name="cover">` added or fixed when exactly one image
  is the cover (`cover-image`, or an id/file named cover)
- `stray-img`: `img` tags without a source are dropped
- `body-id-link`: links (and NCX entries) to a chapter's body id point at
  the file instead
- reported only: manifest items or references (`href`, `src`) to files that
  aren't in the EPUB

Like conversions it works on a copy downloaded through calibre-server and
adds the repaired EPUB back (`add_format`); the KOReader checksum before is
kept in `file_checksums`, and before the first repair the EPUB as it is in
the library is added as format `ORIGINAL_EPUB` (`epubFix.keepOriginal`, on
by default; an existing one is never replaced). A changed event with the
same formats on both sides tells the reading list to copy the file again.
`epubFix.onImport` (off by default) repairs added books with an EPUB
(inbox, upload, calibre) and books that get one (conversion, added format).
`POST /api/epub-fix` (the web app's "EPUBs prüfen" and "EPUBs reparieren"
on the Metadaten page) checks the library or a selection, as a dry run
unless `dryRun: false`. Runs are jobs in a queue of their own; what each
run found per book is in `GET /api/epub-fix/jobs/:id`.

## Reading lists

Lists like playlists, kept in the hub's state DB (calibre Desktop doesn't
see them): name, description, owner, visibility (private, readable,
editable; matters once there is more than one user), sync to the reader,
favorite (shown in the sidebar), default list (the bookmark on the cover)
and the books with the time they were added. Only the owner (or an admin)
changes a list's name, place, description, visibility, sync, favorite and
default flag; others add and remove the books of an editable list (403
otherwise), and a reader never touches sync, neither on nor off. A deleted book leaves its
lists and goes back into them when it is restored from the trash.

Nested lists: the name is the path, `Urlaub/2026` is the sublist `2026`
of `Urlaub`. A level without a list of that name (`Reise` above
`Reise/Meer`) is just a folder in the tree; with one it has books of its
own. A list's page shows its books and those of its sublists (like
categories), "nur direkt" only its own. Renaming a list renames its
sublists (and moves their reader folders); deleting it leaves them.

Magic shelves: a list with a `rule` instead of books of its own, a saved
search shown like a list (sidebar, overview, palette, `?list=`, OPDS). The
rule is conditions joined by AND (`match: "all"`) or OR (`"any"`), each one
`{field, value, not?}` over `tag`, `kategorie` (incl. the categories below
it, `A/B` or `A.B`), `author`, `series`, `language` (calibre's code, `deu`)
or `text` (calibre search syntax, like `q`); at most 20:

```json
{"match": "all", "conditions": [{"field": "tag", "value": "Krimi"},
  {"field": "language", "value": "deu", "not": true}]}
```

The hub turns it into one calibre search (`(tags:"=Krimi") and (not
(languages:"=deu"))`, returned as `query`) and checks it with calibre when
it is saved (400 when calibre can't search it). Its books and count come
from that search on every read, so they follow the library; most recently
added to the library first, the other list sorts apply. A shelf has no
books of its own: adding or removing is a 400, it is never the default list
and never synced to the reader (the reader folders skip it, also below a
synced list). In a node with lists and shelves the lists' books come first,
then the shelves' ones not among them. Only a shelf takes a new `rule`; a
list doesn't become a shelf or the other way round.

Migration: on the first start the books with the tag `leseliste.tag`
(default `leseliste`) become the list "Leseliste", synced, favorite and
default list. The tag stays on the books but is no longer read; the list is
the source of truth from then on.

Visibility is set in the web app ("Liste bearbeiten") and stored per list;
it matters once there is more than one user. Reader apps can add
`https://<hub>/opds/lists` as a catalog of their own. The reader folder changes from category
subfolders to `<target>/Leseliste/`.

Inbox (`inbox.path`): files unchanged for `inbox.stableSeconds` are added
through calibre-server; `A/B/x.epub` gets category `A.B` and tags `A`, `B`,
tags embedded in the file are dropped. Originals move to `_imported/<date>/`
or `_duplicates/<date>/`, after 3 failures to `_failed/<date>/`. Folders the
hub can't write are skipped.

## Backlog import

`backlogImport.roots` (empty: off): folders an old collection may be
imported from, read-only. Unlike the inbox, folders never become categories
or tags, and nothing is moved or deleted.

- A folder with `metadata.opf` (an old calibre library, `Author/Title (12)/`)
  is one book: title, authors, series, tags, identifiers (without the old
  library's calibre id and uuid), description, languages, publisher and
  date from the OPF, the cover from `cover.jpg`, every book file in it a
  format of that book.
- Any other book file is a book with what calibre reads from it; files with
  the same name and another extension in one folder are formats of one
  book. Tags embedded in the file are dropped, like in the inbox.
- Book formats: EPUB, KEPUB, AZW3, AZW, MOBI, PRC, AZW4, FB2, FBZ, DOCX, ODT,
  RTF, PDF, DJVU, CHM, CBZ, CBR, CB7, LIT, PDB, TXT. Files below 2 KiB
  (TXT: 20 KiB) or without their format's signature (`%PDF`, `PK`,
  `BOOKMOBI`, ...) are skipped, as are hidden files, symlinks and the
  inbox's `_imported`, `_duplicates`, `_failed` at the top of the folder.
  Everything else stays where it is and is listed in the report with the
  reason, counted by reason, type and top folder in the summary.
- Duplicates are checked against the library before adding: the same file
  (size, then KOReader's partial MD5 and the first KiB; also files the hub
  rewrote since, by the checksum kept from before), the ISBN, or the same
  title with an author in common, normalized like on the duplicates page
  (case, accents, punctuation, download-site junk; unknown authors are no
  author in common). Two volumes, two numbers of a series or two editions
  of a standard are never duplicates, not even with the same ISBN. Unlike
  the duplicates page, the title must be the same, not only alike.
  Files without an OPF are checked by file before adding and right after by
  what calibre read from them: calibre's own title/author check, then ISBN
  and title/author (the new book is removed again). A duplicate is skipped,
  or adds the formats the library's book lacks (`formatAdded`). Only books
  in the library count: files and checksums of books removed since (also
  those in calibre's trash) match nothing.
- The state DB keeps every file a run handled (`import_files`: path, size,
  mtime, book), so another run of the same folder skips them ("imported
  before") and only takes new or changed files. A file whose book is no
  longer in the library (it was imported, a duplicate of or a format added
  to a book removed or trashed since) is planned again by the next run.

A run is a job: the request returns at once, the job scans the folders and
plans (a large backlog takes minutes; the API stays responsive, the run
shows the files and books found so far, then the books checked), then the
summary: books, formats, calibre folders, covers, to add, formats to add,
duplicates by how they were found, skipped. A dry run ends there and runs
in a queue of its own, beside an import. An import goes on with its books in
the import queue, resumed after a restart (also during the scan); a failed
book is listed and tried again by the next run. There is no stability wait
per file, and while an import runs the metadata, classify, convert and
embed hooks pause (`hooksPaused`), so calibre-server only adds books;
afterwards they work off the new books' events as for any added book.
calibre-server down: the job waits (20 x 15 s), then stops as failed. A
server error for one book (e.g. calibre's `NoSuchBook`) while calibre-server
answers a plain search fails only that book, and the run goes on.

Several folders can go into one run (`paths`), and `limit` imports a
portion: the first N books in scan order (folders as given, then sorted)
that add a book or formats; duplicates on the way go along, the rest is
`deferred`. The next run with the same folders skips what was handled and
takes the next N.

Progress: the web app's Import page (sidebar, command palette, linked from
the Metadaten page) and `hub import status` show the phase (scan, duplicate
check, import, followup), the folder or book a run is at, its running
time, rate and ETA (the import's rate counts only the books since the hub
last started), the results so far with the failed books and why, and the
runs with their cleanups. The whole backlog: books imported, formats
added and duplicates of every import so far (the files they handled), and
what the latest scanned run (its folders) still has open: books and
formats to add, duplicates, failed books; its new books are the imported
ones plus those to add. Followup: the books the metadata, classify,
convert and embed hooks still have to work off (their running jobs or
queue, and the events past their cursor; for convert and classify an upper
bound, they skip books that need nothing). The page polls every 2 s while
a run is going, every 10 s during the followup.

```sh
hub import alt                      # dry run of <first root>/alt
hub import /srv/media/ebooks/inbox --apply --report report.json
hub import alt neu --limit 200 --apply   # the next 200 books of both
hub import status                        # phase, backlog, followup, runs with rate and ETA
```

Cleanup of an inbox import (`POST /api/import/cleanup`, `hub import
cleanup`): for books the inbox added (an `added` event since `since`, or a
book id from `minId` to `maxId`) the folder path is read from the hub's
events (the first state of the book with a category: the category and tags
the inbox set together). The category is cleared when it is still that
path, and exactly the tags that are a folder of the path are removed; other
tags and a category set since stay. A dry run lists the books; applied, the
previous values go to the state DB and
`/var/lib/calibre-hub/import-cleanup-<id>.json`, and `undo` puts them back.
Running it again finds nothing left to do.

```sh
hub import cleanup --since 2026-11-02T18:00        # dry run, local time
hub import cleanup --min-id 114 --apply
hub import undo <cleanup id> --apply
```

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
   "Mckeown"/"MCKEOWN" as "McKeown" ("MACDONALD" as "MacDonald", but a
   "Macdonald" written so stays, and "Mack", "Macy" and the like are names
   of their own), a broken author sort (one that shares no name with the
   authors). A "(1974, Tonos)" or "(, TRO Hollis Music, Inc.)" at the end
   of a title goes, its year and publisher fill an empty date and
   publisher (source `rules`, after an edition found by ISBN). When
   the rules can't tell author from title (`Wolken - Atlas`) and
   `metadata.useModel` is on, the classify model is asked, with title and
   authors only; its answer is used only if every word in it was in the
   input.
3. Sources (`metadata.sources`, default `file hardcover dnb openlibrary`):
   ISBNs first (calibre's, the OPF's, the text's) at every source; title
   and author search only when no ISBN gave a sure match, and only where
   the book fits the source:
   - **Hardcover** (GraphQL, needs `metadata.hardcoverTokenFile`): editions
     by ISBN-13/10. A title search needs the author; a hit counts only with
     a title similarity of at least 0.9, the same author, no placeholder
     ("Untitled") and no book about the book (summary, workbook), and the
     work needs an edition in the book's language (`language.code3`;
     unknown: German for a German-looking title, else English). ISBN,
     publisher and date come only from a clear edition (the only one in
     that language, or the only one of the book's publisher), never from
     the work (`release_year`).
   - **DNB** (SRU, MARC21): a title search only for German books (language
     `deu`, or none and a German-looking title), always with `per=`
     (surname) and `spr=ger`.
   - **Open Library** (books and search API) as the supplement.

   Candidates that aren't this book are dropped: a translation (DNB 041 h,
   240 or a translator in 700 $4 `trl`) when the book isn't German, another
   language (DNB 041 a), another volume (245 n/p "Vol. 3" for a book "Vol.
   1"). A match by the book's own ISBN (calibre's or the OPF's) is always
   kept: it is this edition.
4. Score 0..1: title 60 %, authors 30 %, language and year 10 %. A match
   by ISBN is **sure** when the ISBN is in calibre or the OPF, or when the
   result also agrees with the book (score ≥ 0.5; an ISBN on an ad page
   doesn't). A text match from 0.75 is **accepted**.
5. Merge per field: rules' title and authors, then the file, then the
   candidates in the field's order of sources (from the comparison runs):

   | Field | Order |
   |---|---|
   | description | Hardcover, DNB, Open Library |
   | author spelling | sure (ISBN) matches first, then Hardcover, DNB, Open Library |
   | publisher, date, language | file, sure matches (DNB, Open Library, Hardcover), `rules` (title suffix), other matches |
   | series | file, then DNB, Hardcover, Open Library |
   | subtitle | only Hardcover's, added to the same title without one |

   Missing fields are filled from an accepted candidate (ISBN, publisher
   and date only from one edition, not a work with many; a year alone
   takes the full date of another source with that year); an existing
   value is replaced only when it is broken, by a sure match that clearly
   differs (publisher, year, language, a completely different title; never
   by Hardcover's publisher, year or language), or by the same value
   spelled better (case, accents, "McKeown", "Le Guin" for "LeGuin",
   "J. R. R. Tolkien" for "Tolkien"). A sure match naming all of the
   book's authors and more adds the co-authors. Descriptions are only
   filled; a cover only for books without one.
6. One `PATCH` with `lastModified`; a book changed meanwhile is tried once
   more, then on the next run.

Standards (`Meta::Norms`): a title in the file-name form
`[DIN EN ISO 11073-10404 2011-07] -- …` (calibre split the rest at the last
" - " into title and author; also prestandards `[DIN V ENV 13606-2 …]`,
amendments `[DIN EN ISO 14971 A1 Entwurf 2003-01]` as
`DIN EN ISO 14971/A1` and corrigenda `[DIN EN ISO 14971 Berichtigung 1
2007-10]`), or exactly a designation like
`ISO/IEC 42001:2023` by an issuing body, is a standard; books about
standards are not. Its fields come from the rules alone, no online source
is asked: title `DIN EN ISO 11073-10404:2011-07 – Pulsoximeter` (the most
specific part, "(Entwurf)" for drafts), the full title as description (only
when there is none; cut-off titles are completed from the PDF's cover
page), author the issuing body (DIN, ISO, IEC, CEN for EN), publisher Beuth
for DIN, date from the edition, language from "Englische/Deutsche Fassung",
series the standard with the part as number, identifier `din`/`iso`/`iec`,
tags `Norm`, `Entwurf` and `ersetzt` (an older edition when a newer final
one of the same designation is in the library; the newer one's run tags
the older ones too). The tags are logged as the field `tags` (only these
three) and reverted like the other fields.

Author unification: a library-wide pass groups names by a key without
case, accents, punctuation, spaces and "Last, First" and renames every
variant to the best form: proper case ("McKeown"), then confirmed by
Hardcover/Open Library/DNB, then the most books. Logged and revertible like
the rest.

Runs are jobs in a queue of their own, resumed after a restart:
`POST /api/metadata/run`, nightly at `metadata.nightly` (off by default;
incomplete books plus the author pass) and for every added book. A new
book is classified only after its metadata run is done or failed (at most
30 minutes later). "incomplete": books missing ISBN, publisher, date,
language or description, or with messy names; books checked in the last 30
days without a failed source are skipped. Requests to a source are spaced
by `metadata.requestInterval` ms (Hardcover allows about 60 a minute, the
default 1000 ms keeps below).

Hardcover token: a personal token from https://hardcover.app/account/api
(with or without "Bearer "), set as `metadata.hardcoverTokenFile` and passed
as a systemd credential (`CALIBRE_HUB_HARDCOVER_TOKEN_FILE`; for development
also `CALIBRE_HUB_HARDCOVER_TOKEN`). Without one the source is skipped. When
Hardcover rejects it (401/403), the source pauses for an hour, the other
sources go on (the book isn't marked for retry) and `alertCommand` is called
with "calibre-hub: Hardcover-Token abgelaufen oder ungültig", at most once a
day (kept in the state DB, so a restart doesn't repeat it). A JWT token is
also checked for its `exp` (decoded, not verified): from 14 days before
expiry the alert "Hardcover-Token läuft bald ab" comes once a day.

## Hardcover sync

`hardcoverSync.enable` (off by default) keeps Hardcover in step with the hub,
in one direction (hub -> Hardcover), with the token and client of the
metadata source (same pause and alerts; requests share
`metadata.requestInterval`). Every `hardcoverSync.interval` seconds (900):

1. **Books -> Hardcover books** (read-only): up to `hardcoverSync.batch`
   books (100) per run, newest first, are looked up: in the user's own
   Hardcover library (ISBN, then a very similar title by the same author),
   then by ISBN, then by a title and author search (like the metadata
   source: an edition in the book's language). The match (book, edition,
   pages) is kept in the state DB (`hardcover_books`, not in calibre); a
   book not found is looked up again after 30 days, any book again when its
   ISBN, title or first author changes.
2. **Reading progress -> status**: the newest position per book of
   `hardcoverSync.user` (default `login.user`) whose progress changed since
   the last run. From 2 % the book is "Currently Reading" with the pages
   read (progress x the edition's pages) in its open read (one is added
   with today's date as start when there is none); from
   `hardcoverSync.readAt` (0.98) it is "Read" and the open read gets the
   finish date. Only books without a status or with "Want to Read" or
   "Currently Reading" are changed: "Read", "Paused", "Did Not Finish" and
   "Ignored" were set on Hardcover and stay (no re-read from the hub).
   Ratings, reviews, lists and "Want to Read" are never written; nothing
   comes back from Hardcover.

**Private books**: a book tagged with one of `hardcoverSync.privateTags`
(`Private`, `privat`; any case) is never sent to Hardcover, neither for
matching (no title or ISBN) nor its progress. Tagged after it was synced,
the hub takes back what it wrote: reads it added and a user book it created
are deleted (`delete_user_book_read`, `delete_user_book`; what the hub
created is kept in `hardcover_created`), a user book that was there before
(e.g. from an import) is kept with its history and set private
(`privacy_setting_id` 3). Without the tag again, that user book gets its
earlier privacy back and the book syncs as usual on the next run.

Without `hardcoverSync.write` (default) it is a dry run: matching runs, the
planned writes are logged once per progress change
(`journalctl -u calibre-hub | grep 'hardcover sync: dry run'`), nothing is
sent. Switched to write, the books planned in the dry run are planned again
and sent.

## CLI

`hub <command>`, or `calibre-hub cli <command>` (the same client in the
server binary, without `tui`), talks to a running hub with an API token. `CALIBRE_HUB_URL` (default
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
hub list ls --tree                       # nested lists indented, levels without a list end in /
hub list show Leseliste --sort title
hub list show Urlaub/2026 --direct       # a sublist; --direct: without its sublists' books

hub list create Urlaub --description 'Für den Strand' --sync --favorite --visibility private
hub list add Leseliste 12 13
hub list rm leseliste 12
hub list delete Urlaub --yes
hub upload *.epub --tag neu --kategorie Roman/Krimi
hub upload dune.pdf --add-format-to 12
hub bulk --query 'series:"=Dune"' --kategorie Roman.SF --yes
hub bulk --ids 12,13 --add-tags a,b --remove-tags c --series Dune --number-series --yes
hub import alt                           # backlog import: dry run, --apply imports, --limit N a portion
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
the packages install them for `hub` and `calibre-hub`.

The repository builds two binaries (targets in `shard.yml`):

| Binary | Entry | Package | What |
|---|---|---|---|
| `calibre-hub` | `src/main.cr` | `packages.server` | serve, scan, install-triggers, handlers, `cli` (all but `tui`); what the NixOS module runs |
| `hub` | `src/hub.cr` | `packages.hub` | the CLI with `tui`; links bubbletea.cr and its Go library |

`packages.default` has both (for a workstation). The server binary doesn't
link bubbletea.cr, so the Go library is not in the server's closure;
`calibre-hub cli tui` points to `hub tui`. A Claude Code skill for the CLI is in
[docs/skills/calibre-hub/SKILL.md](docs/skills/calibre-hub/SKILL.md)
(copy it to `~/.claude/skills/calibre-hub/`).

### TUI

`hub tui` browses and edits the library in the terminal, with the same token
as the CLI: the books as a table (title, authors, series,
category, tags), newest first, loaded page by page where the cursor goes;
the web app's sidebar (lists, categories with "Ohne Kategorie", fast tags,
authors, series, tags, languages); a book's detail with its description.
Colours follow the terminal's light or dark background.

| Keys | |
|---|---|
| `j`/`k`, `gg`/`G`, `Ctrl-d`/`Ctrl-u`, `Ctrl-f`/`Ctrl-b` | move; a count in front repeats (`5j`) or picks the line (`12G`) |
| `Enter` | open the book; in the sidebar: filter on/off |
| `/` | search (calibre syntax, like the web app's search field); `n`/`N` next/previous result, in a book the next/previous book |
| `h`/`l`, `Tab` | sidebar and library; in the sidebar `l`/`h` unfold/fold |
| `o`/`O` | change the sort / reverse it |
| `gl` | all books (filters off) |
| `q`, `Esc` | back (end visual mode, clear the selection, close the book, previous filter); `q` at the start quits |
| `?` | all keys (`j`/`k` scroll) |
| `e`, `F2` | edit the book: a form for all fields, `Tab` completes (authors, series, category, tags, languages) or moves on, `↑`/`↓` field, `Ctrl-s` saves only the changed fields; on a conflict (409) both versions show, `m` keeps mine on top of the new one, `t` takes the new one |
| `Space` | select or unselect the book; commands then act on the selection |
| `v`, `V` | visual mode: moving selects from where it started (on top of what was selected); `v` or `Esc` ends it, a command ends it too and the range stays selected |
| `Ctrl-a` | all matches of the search (sent as `{query, expect}` with the count shown; 409 when the library changed meanwhile, nothing is changed) |
| `Shift-↓`/`Shift-↑` | extend the selection |
| `.` | the last change again (command, fast tag, default list) on the selection or the cursor book |
| `T` then `1`-`9` | toggle a fast tag (shown at once, taken back if the hub refuses) |
| `t` | the default list on or off |
| `dd`, `Del` | to calibre's trash (asks) |
| `D` | download the file (EPUB first) into the current directory |
| `u` | undo the last change |
| `gt` | calibre's trash: `r` restores the cursor entry or the selection (`Space`, `v`, `Ctrl-a`; several ask), one after another with the progress in the status line; `u` deletes them again; `q` back |
| `:`, `>` | command line: `Tab` completes commands and values (cycles on repeat), `↑`/`↓` history (kept in `$XDG_STATE_HOME/calibre-hub/tui-history`) |

Commands (`:`) use the CLI's words, German ones like the web palette, or
the web app's action ids (`:addTags x`): `tag add|rm TAGS`, `kategorie A/B`,
`serie NAME`, `nummerieren NAME` (volumes 1..n in selection order),
`autor A & B`, `verlag`, `sprache deu, eng`, `bewertung 0-5`, `jahr 1999`
(`-` clears), `list add|rm|new NAME`, `trash`, `download [FORMAT]`, `edit`,
`open`, `search Q`, `sort FIELD [asc|desc]`, `select all|none`, `undo`,
`repeat`, `papierkorb`, `restore`, `fehler` (the books a job failed for),
`help`, `quit`, a number jumps to that line. They follow the web app's book actions
(`frontend/src/lib/book-actions.ts`): one book is changed right away
(`PATCH`), a selection as a bulk job (`POST /api/books/bulk`, progress in
the status line); more than 50 books and deleting ask first. Undo: one book
back to its previous values (`PATCH` with the `lastModified` of the change),
lists the other way round, deleted books from the trash, bulk field changes
through `POST /api/jobs/:id/undo` (hubs without it say so). Bulk changes of
authors, publisher, languages, rating or year need a hub whose bulk API has
those fields. A visual range over rows not loaded yet loads them first (a
range over all rows is sent as all matches); all matches can't be numbered,
downloaded or undone after deleting (they are in the trash).

Own keys: `$XDG_CONFIG_HOME/calibre-hub/tui-keys.json` (`~/.config/...`), in
the format of the web app's `hub.keymap.vim` (the action names of
`frontend/src/lib/keymap.ts`, plus the TUI's own: `sort`, `order`,
`switchPane`, `searchNext`, `searchPrev`, `fastTag`, `undo`, `repeat`,
`restore`, `quit`). Own bindings replace the defaults of the actions they
name and win over default keys; `"leader"` sets what `<Leader>` stands for
(default `\`), the web app ignores it. Actions only the web app has are
left out, anything else unknown shows in the status line.

```json
{"leader": ",", "goTrash": ["<Leader>t"], "down": ["j", "<Down>"]}
```

It is built on [bubbletea.cr](https://github.com/leoc/bubbletea.cr) (Crystal
bindings for Bubble Tea, Lip Gloss, Bubbles and Glamour through a Go
library), so only the `hub` binary links `libbubbletea_go.so`
(`nix/hub.nix`).

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
    # further users; role "admin" or "reader" (default)
    users.lea = { role = "reader"; passwordFile = "/run/secrets/hub-lea"; };
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
      # defaults: sources = [ "file" "hardcover" "dnb" "openlibrary" ]; nightly = null; useModel = classify.enable;
      # hardcoverUrl, openLibraryUrl, openLibraryCoversUrl, dnbUrl (the public services); requestInterval = 1000;
      nightly = "03:15";
      hardcoverTokenFile = "/run/secrets/hardcover-token";  # null: no Hardcover
    };
    # with metadata.hardcoverTokenFile; dry run until write = true
    # hardcoverSync = { enable = true; write = false; interval = 900; batch = 100; readAt = 0.98;
    #   privateTags = [ "Private" "privat" ]; };
    # embed = { enable = true; delay = 60; };  # the defaults
    convert = { enable = true; target = "EPUB"; ignore = [ "PDF" "CBZ" "CBR" ]; };
    # duplicates.threshold = 0.85;  # the default
    epubFix.onImport = true;  # keepOriginal = true is the default
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
shards build && bin/calibre-hub serve   # API on 127.0.0.1:8084 (also builds bin/hub)
shards build hub && bin/hub tui         # CLI and TUI only
crystal spec
nix build                               # both binaries; .#server or .#hub alone
```

After changing dependencies: `shards install && crystal2nix`.

bubbletea.cr comes from GitHub (`leoc/bubbletea.cr`, in `shard.yml` and as the
flake input `bubbletea-cr`; keep both on the same tag). Its Go library comes
from the flake (`BUBBLETEA_LIB_DIR` in the dev shell), so the dev shell needs no
Go. `crystal2nix` writes a `bubbletea` entry into `shards.nix`: remove it,
`nix/hub.nix` links the flake input instead and the server package
(`nix/package.nix`) doesn't need it.

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
| `CALIBRE_HUB_API_TOKEN_FILES` | none | comma separated files, one API token (≥ 16 characters) each, of the login user |
| `CALIBRE_HUB_USERS` | none | further users, comma separated `name:role:passwordFile[:tokenFile\|tokenFile…]`, role `admin` or `reader` |
| `CALIBRE_HUB_CLASSIFY` | `false` | `true` turns on category suggestions (needs `CALIBRE_HUB_CATEGORY_COLUMN`) |
| `CALIBRE_HUB_CLASSIFY_ENDPOINT`, `_MODEL` | `http://127.0.0.1:11434`, `qwen2.5:3b` | Ollama API and model |
| `CALIBRE_HUB_CLASSIFY_THRESHOLD`, `_SCHEDULE`, `_TIMEOUT` | `0.85`, `03:45`, `300` | auto-apply from, nightly run (empty: none), seconds per answer |
| `CALIBRE_HUB_METADATA` | `false` | `true` turns on the metadata cleanup |
| `CALIBRE_HUB_METADATA_SOURCES`, `_NIGHTLY`, `_MODEL`, `_INTERVAL` | `file,hardcover,dnb,openlibrary`, none, `false`, `1000` | sources, nightly run, clean names with the classify model, ms between requests |
| `CALIBRE_HUB_EMBED`, `_EMBED_DELAY` | `false`, `60` | embed metadata into the files after edits (the module turns it on), seconds after the last edit |
| `CALIBRE_HUB_CONVERT`, `_CONVERT_TARGET`, `_CONVERT_IGNORE` | `false`, `EPUB`, `PDF,CBZ,CBR` | convert added books, target format, formats never converted from |
| `CALIBRE_HUB_DUPLICATES_THRESHOLD` | `0.85` | how alike two titles of one author must be to show as duplicates (0.5..1) |
| `CALIBRE_HUB_EPUB_FIX_ON_IMPORT`, `_EPUB_FIX_KEEP_ORIGINAL` | `false`, `true` | repair the EPUBs of added books, keep the EPUB before the first repair as ORIGINAL_EPUB |
| `CALIBRE_HUB_OPENLIBRARY_URL`, `_OPENLIBRARY_COVERS_URL`, `_DNB_URL`, `_HARDCOVER_URL` | the public services | base URLs (stubs in the VM test) |
| `CALIBRE_HUB_HARDCOVER_TOKEN_FILE`, `_HARDCOVER_TOKEN` | none | Hardcover API token (file first); none: source skipped |
| `CALIBRE_HUB_HARDCOVER_SYNC`, `_SYNC_WRITE`, `_SYNC_USER` | `false`, `false`, `CALIBRE_HUB_LOGIN_USER` | Hardcover sync, write (else dry run), whose progress |
| `CALIBRE_HUB_HARDCOVER_SYNC_INTERVAL`, `_SYNC_BATCH`, `_SYNC_READ_AT` | `900`, `100`, `0.98` | seconds between runs, books looked up per run, progress counted as read |
| `CALIBRE_HUB_HARDCOVER_SYNC_PRIVATE_TAGS` | `Private,privat` | tags that keep a book off Hardcover |
