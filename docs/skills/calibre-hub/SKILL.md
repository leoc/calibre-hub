---
name: calibre-hub
description: Search, inspect, download, edit, tag, upload and bulk-change books in Arthur's calibre library through the calibre-hub CLI (`hub`, same as `calibre-hub cli`). Use whenever Arthur asks about his books, e-books, the calibre library or the hub (hub.nor.sh), wants to find or show a book, fix metadata (title, authors, series, category/Kategorie, tags, description, ISBN), put books on a reading list (Leseliste or any other list), manage lists, upload e-book files, or change many books at once.
---

# calibre-hub CLI

`hub <command>` talks to the hub's API (`CALIBRE_HUB_URL`, default
https://hub.nor.sh) with the token from `CALIBRE_HUB_TOKEN`,
`CALIBRE_HUB_TOKEN_FILE` or `~/.config/calibre-hub/token`. If `hub` is not
on PATH, use `calibre-hub cli`. `hub <command> --help` lists all options.

**Always pass `--json` when you parse the output**; the default tables are
for humans and get cut. Errors with `--json`: `{"error", "exitCode", ...}`
on stdout. Exit codes: 0 ok, 1 usage/invalid input, 2 not found,
3 conflict or duplicate, 4 token missing/wrong, 5 hub or calibre-server down.

## Read

```sh
hub search 'title:dune' --json                  # calibre search syntax
hub search --author 'Frank Herbert' --series Dune --sort series --json
hub search --kategorie Fachbuch/Software --tag leseliste --limit 500 --json
hub show 12 --json                              # all fields incl. comments (HTML)
hub categories kategorie --json                 # also: tags authors series languages
hub download 12 --format epub -o /tmp/dune.epub
hub cover 12 -o /tmp/cover.jpg
```

Search JSON: `{total, offset, limit, books: [{id, title, authors, series,
seriesIndex, tags, formats, lastModified, pubdate, rating, publisher,
identifiers, languages, custom: {kategorie}}]}`. Page with `--offset` when
`total` > `limit` (max 500). Query examples: `tags:"=sf"`,
`authors:herbert and not tags:gelesen`, `#kategorie:"=.Roman"`.

## Write

Show the book first and tell Arthur what you will change; for more than a
few books ask before running.

```sh
hub edit 12 --title 'Dune' --authors 'Frank Herbert,Brian Herbert' --json
hub edit 12 --series Dune --index 2 --kategorie Roman/SF --pubdate 1969-01-01
hub edit 12 --rating 8 --identifier isbn=9780441013593 --publisher Ace
hub edit 12 --series ''                          # empty value clears
hub edit 12 --comments-file /tmp/desc.html       # or - for stdin
hub tag add 12 13 sf
hub tag rm 12 sf
hub upload a.epub b.pdf --tag neu --kategorie Roman/Krimi --json
hub upload dune.pdf --add-format-to 12           # extra format for a book
hub bulk --ids 12,13,14 --add-tags sf --yes --json
hub bulk --ids 7,3,9 --series Dune --number-series --yes --json   # 1, 2, 3 in id order
```

- Categories (Kategorie) are hierarchical: `A/B` and `A.B` both mean `A.B`.
- `--tags` on edit replaces all tags; use `tag add|rm` to add or remove one.
- `--rating` is 0-10 (half stars, 8 = 4 stars).
- edit exit 3: the book changed meanwhile, nothing was written. Show it
  again and retry on top of the new state.
- upload goes through the Eingang: `"status": "added"` is in the library,
  `"waiting"` stays in the Eingang below the threshold for Arthur to decide
  (hub.nor.sh/eingang), `"checking"` means the analysis wasn't through within
  `--wait` (120 s). `hub eingang` shows what waits there.
- files come in by upload or the inbox folder, there is no other import
  (`hub import <folder>` is gone). What the Eingang throws away lands in one
  trash folder (on dmt `/srv/media/ebooks/papierkorb`), below `inbox/` or
  `upload/` under its path there; nothing in it is deleted, Arthur empties it.
- upload exit 3 with `"status": "duplicate"` or `"copy"`: the library already
  has the book (`duplicates` lists them), nothing was added. Only use `--force`
  if Arthur wants a copy; `--add-format-to` goes straight to that book.
- bulk without `--yes` refuses outside a terminal, so always pass it, after
  checking the count with `hub search ... --json` (`total`). Its JSON is
  the finished job: `{status, done, total, errors: [{bookId, error}]}`.

## Reading lists

Lists are like playlists and live in the hub (calibre itself doesn't see
them). The reading list is the list "Leseliste" (default list, synced to
the Boox); the tag `leseliste` is no longer read, so never use tags for it.
A list is named by id or name (ignoring case).

```sh
hub list ls --json                               # [{id, name, count, isDefault, sync, favorite, visibility, ...}]
hub list show Leseliste --json                   # {list, books: {total, books}}; --sort listAdded|title|author|series
hub list add Leseliste 12 13                     # put on the reading list
hub list rm Leseliste 12
hub list create 'Urlaub 2027' --description 'Für den Strand' --sync --favorite
hub list delete 'Urlaub 2027' --yes              # books stay in the library
hub search --json ... | jq '.books[].lists'      # every book has the ids of its lists
```

- `sync`: the list is mirrored to the reader, one folder per list.
- add reports the books that were new; ids already in the list (or
  unknown) are named on stderr.
- `delete` without `--yes` refuses outside a terminal; ask Arthur first.
- Reader apps get each list as an OPDS catalog: `/opds/lists` (Basic auth
  like `/opds`).
