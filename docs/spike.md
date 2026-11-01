# Spike: Crystal proxy on calibre-server (Phase 0, Redmine #8389)

Date: 2026-11-01. Result: **Go for Crystal.**

## What was built

- `flake.nix` with a dev shell (crystal 1.19, shards, crystal2nix, calibre) and
  `packages.default` via `crystal.buildCrystalPackage` + `shards.nix` from
  crystal2nix.
- `Calibre` client: talks to calibre-server like calibredb does, via
  `POST /cdb/cmd/<name>/<version>` with JSON arguments and Basic auth on
  localhost.
- `GET /api/books[?q=<calibre search>]`, `GET /api/books/:id`, `/healthz` (Kemal).
- `Detector`: full scan, snapshot per book in SQLite, events `added`,
  `changed` (`{field: [old, new]}`, custom columns as `#name`), `deleted`,
  written to an `events` table (queue columns already there). `serve` scans on
  start, ~2 s after `metadata.db` changes, and every 15 min.
- `dev/testlib.sh`: test library with four books and `#kategorie`, calibre-server
  on 127.0.0.1:18083 (user hub/hub).

## Findings about calibre-server (9.17 local, 9.15 on dmt)

- `/cdb/cmd/<name>/0` accepts `application/json`; the body is the positional
  argument list of the command's `implementation()` without `db` and
  `notify_changes`. `list`: `[fields, sort_by, ascending, search, limit]`;
  `limit` must be `-1`, not `null`.
- Custom columns are requested as `*name` and come back as `#name`.
- Datetimes come wrapped as `{"<marker>": 0, "v": "<iso>"}` and mix time zones
  (`+00:00` from import, local offset after edits).
- Remote `list` returns format names only (no paths). Downloads go through
  `/get/<fmt>/<id>`.
- `series_index` is `1.0` even without a series; the API should return `null`.
- `last_modified` changes on metadata edits and on `add_format`. It has second
  resolution after import, so it is not a safe cursor. The detector therefore
  always diffs the full snapshot; `last_modified` is only shown.
- While calibre-server runs, local `calibredb --with-library <path>` is refused
  (library lock). All writes have to go through the server, which is what we
  want anyway.
- `calibre-server --manage-users -- add/chpass` reads the password from stdin
  including a trailing newline; password files must not end with one.

## Crystal / Nix

- `shards build` (debug) a few seconds, Nix release build ~35 s.
- crystal2nix + `buildCrystalPackage` work without patches. The install check
  runs `calibre-hub --help`, so that must not need configuration.
- Kemal 1.15, crystal-sqlite3 0.24: no friction. Detector live event about
  3 s after a change; API answers in 5–12 ms on the test library.

## Risks and follow-ups

- Scan time on a large library is untested (dmt has ~60 books). If it gets
  slow: fetch only `id,last_modified` first and the full rows for changed ids
  (with an overlap window), keep the full scan as a periodic reconcile.
- calibre version drift: pin nixpkgs to the same input as nixos-config
  (`inputs.nixpkgs.follows`) so dev, VM test and dmt use one calibre version.
  `/cdb/cmd` checks the command version and answers 404 on a mismatch, which
  the smoke test will catch.
- Sessions/CSRF: no shard needed; signed cookie with HMAC from a sops secret is
  a few dozen lines (Phase 1).
- Error mapping: calibre-server down currently ends in a 500; map to 502 with
  a JSON body (Phase 1).

## Changes to the plan

None to the phase cut. Phase 1 additionally gets: nixpkgs `follows`,
`series_index = null` without series, 502 mapping.
