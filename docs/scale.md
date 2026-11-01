# Scale test: 10,000 books

`nix build .#scale-test -L` (NixOS VM, 4 cores, 4 GiB, KVM on shmoz;
calibre 9.14 from nixos-26.05). Books without files: 2,000 authors, 52
tags, 300 series, 200 `#kategorie` paths. One handler that logs every
event with `jq`.

| Case | Result | Limit |
|---|---|---|
| Generate the library (direct SQL) | 2.5 s | |
| First start: snapshot of 10,000 books | 0.5 s in the hub, 1.1 s from start | < 60 s |
| Single change -> event at the handler | 1.2–2.2 s | < 5 s |
| 1,000 writes through calibre-server (8 parallel) | 18.6 s | |
| ... all 1,000 events detected | 20.7 s (2 s after the last write) | |
| ... all 1,000 events at the handler | 43.0 s | < 60 s |
| Tag on 4,999 books renamed while calibre-server was stopped: detected after restart | 6.1 s | |
| ... all 4,999 events at the handler | 186 s | |
| Reconcile without changes (restart) | 0.3 s, 0 events | < 10 s |
| Hub memory peak | 56 MiB | |
| state.sqlite | 8 MiB | |

2026-11-02.

## Findings

- Detection is not the bottleneck. Delivery is: every event starts the
  handler process (~20–40 ms in the VM). For bulk changes a handler that
  takes a batch of events would be much faster; not needed yet.
- Found and fixed by this test: fetching more than a few hundred books with
  one `id:1 or id:2 ...` search fails in calibre ("maximum recursion depth
  exceeded"), and the hub retried the same batch forever. Now up to 20 ids
  use the search, more use one `list` call filtered locally (~0.5 s for
  10,000), and three failures in a row fall back to a reconcile.
- The reconcile after the rename fetched 501 books whose `last_modified`
  differed from the snapshot but produced no events, so the snapshot was
  right and only the stored timestamp lagged. Harmless (0.3 s); worth a look
  if it grows.
