# calibre-hub web app

Vite + React + TypeScript, TanStack Router and Query, shadcn/ui-style
components on Tailwind 4. Static build, served by the hub
(`CALIBRE_HUB_FRONTEND`, SPA fallback). UI texts are German
(`src/i18n/de.ts`; another language is a file with the same keys).

## Development

```sh
pnpm install
pnpm dev          # proxies /api to https://hub.nor.sh (HUB_URL=… to change), log in with the real user
pnpm dev:mock     # MSW mock library (400 books, VITE_MOCK_BOOKS=10000 for more), password "hub"
pnpm test         # vitest
pnpm lint && pnpm typecheck
CHROMIUM_PATH=$(which chromium) pnpm e2e   # Playwright against the mocks: *.spec.ts and the Gherkin scenarios in e2e/features (playwright-bdd), desktop + phone
```

Don't start a local calibre-server for development: calibre allows one
program per user and that blocks calibre Desktop.

`nix build .#frontend` builds `dist/` and runs lint, typecheck and unit
tests. After changing dependencies set `hash = lib.fakeHash` in
`package.nix`, build once and take the reported hash. pnpm in nixpkgs is 11;
the lockfile (v9) works with 10 to 12.

## Design

- Library state lives in the URL (`?q=&kategorie=&unsorted=&tag=&author=&series=&lang=&sort=&order=&page=&book=`),
  plain query strings with repeated `tag`. Pages of 60 instead of infinite
  scroll (one redraw per page on E-Ink).
- Categories are shown and typed as paths (`Sachbuch/Geschichte`) but stored,
  in URLs and the API, with dots as calibre does (`src/lib/kategorie.ts`).
  `?unsorted` lists books without a category (`#kategorie:false`); saving a
  category there opens the next one in the form.
- Desktop (≥ 1024 px): sidebar with fast tags, category tree, authors,
  series, tags, languages; book detail as a side panel (`?book=`). Smaller
  screens: sidebar as drawer, detail as its own view. `/books/:id` is a
  permanent link.
- Search and command palette, specified in `e2e/features/search.feature`:
  wide screens (≥ 640 px) search the library live from the header; a prefix
  at the start (`a ` author, `s ` series, `t ` tag, `k ` category, `b `
  books, `>` commands) hands over to the palette, as do the command button
  and Ctrl+K. Narrow screens open the palette full screen from the
  search bar, with scope chips instead of typed prefixes.
- Keyboard control, specified in `e2e/features/keyboard.feature`
  (`src/lib/keymap.ts` bindings and key parser, `src/lib/keyboard.ts` state,
  `src/components/keyboard.tsx` the one keydown listener and the list's
  keys, `keyboard-panels.tsx` hints, help and settings). Two modes per
  device (`hub.keys`), switched in the sidebar footer or with the palette
  commands "Tastatur: App" / "Tastatur: Vim"; `?` shows the keys of the
  current mode.
  - App: arrows, Home/End, PageUp/PageDown, Enter opens, Space selects,
    Shift+arrows extend, Ctrl+A selects the page, F2 edits, Delete deletes
    (asks; with a selection the bulk delete), Alt+←/→ go back and forward.
  - Vim: the app keys plus hjkl, counts (`5j`), `gg`/`G`, Ctrl+D/U, `[`/`]`
    pages, `v` visual mode, `H`/`L` back and forward, `gl` library, `gt`
    trash, `gm` metadata, `gv` suggestions, `gc` category tree (j/k move,
    l/h open and close, Enter filters, Escape back to the books), `f`/`F`
    hints (letters on every book and link; `f` opens, `F` selects a book or
    opens a link in a new tab), and on the active book `e` edit, `t`
    reading list (the first fast tag), `dd` delete, `y` copy its link, `D`
    download the first format. Visual mode, a pending count or sequence
    and messages show top right.
  - In the open detail j/k (arrows) go to the next/previous book. `/` puts
    the focus into the wide search bar (phones: the palette); Enter
    searches and goes on in the list from the first result, Escape returns
    to the list. `>` opens the palette's commands, with books selected the
    bulk commands with the count ("Tags hinzufügen (3)"). Selection uses the
    bulk store and turns selection mode on.
  - Keys do nothing in text fields and while a dialog is open; the active
    book is a roving tab stop with real focus and a ring (thick black in
    E-Ink).
  - Own bindings (gear next to the mode switch, or "Tastenbelegung" in the
    palette) are stored per device and mode in `localStorage` as
    `hub.keymap.app` / `hub.keymap.vim`: a JSON object from action to a
    list of keys, holding only the actions that differ from the defaults;
    an action named there loses its default keys, `[]` unbinds it.
    Keys are written like Vim: a printable character is itself (`j`, `G`,
    `>`), other keys `<Name>` with optional `C-` (Ctrl/Cmd), `A-` (Alt),
    `S-` (Shift): `<Down>`, `<S-Down>`, `<C-d>`, `<A-Left>`, `<Space>`,
    `<Enter>`, `<Esc>`, `<Del>`, `<F2>`, `<PageDown>`; a sequence is the
    keys in a row (`gg`, `dd`). Actions: `down up left right first last
    halfDown halfUp nextPage prevPage open toggleSelect extendDown extendUp
    extendLeft extendRight visual selectAll search commands edit toggleList
    delete copyLink download back forward goLibrary goTrash goMetadata
    goSuggestions goCategories hints hintsSelect help`. Example:
    `{"down": ["n", "j", "<Down>"], "toggleList": []}`.
- Themes: system, light, dark, E-Ink (black on white, no animations, larger
  targets), stored per device. Boox/Onyx user agents get a one-time prompt.
- Category suggestions (`/suggestions`, sidebar entry with the open count,
  palette command "Vorschläge") only when `GET /api/config` says
  `classify`: accept, change (category combobox), reject, accept several;
  "Unsortierte klassifizieren" starts a run and polls its job. The book
  detail shows an open suggestion with accept and reject. The mocks start
  with 5 open suggestions; a run decides by id (`id % 3`: 0 applied with
  the tag `auto-kategorie`, 1 open, 2 no fit).
- Metadata cleanup (`/metadata`, sidebar entry and palette command
  "Metadaten") only when `GET /api/config` says `metadata`: status line
  (sources, model, nightly run, last run), runs "Unvollständige prüfen",
  "Alle prüfen" and "Autoren vereinheitlichen" with job polling, and the
  changed books from `GET /api/metadata/changes` grouped per book (field,
  before → after, source), each change or all of a book revertable, several
  books selected at once; "Zurückgesetzte anzeigen" adds reverted changes,
  greyed. The edit form gets "Metadaten holen": candidates of the book file,
  Open Library and DNB (score, "sicher" on an ISBN match, source link);
  "Übernehmen" puts a field into the form (ISBN into the identifiers), saved
  with the form; a cover is set right away. The mocks start with five
  changed books at the end of the library (a z-lib file name with author
  "Unbekannt" filled from the DNB, two Le Guin books with the author
  spelling unified, Kahneman, a series with a reverted publisher) and an
  unresolved "Gaiman, Neil"; a run fills missing fields by id (`id % 4`:
  ISBN, publisher, date; Open Library times out for `id % 53`), reverts
  restore the fields and drop the `auto-metadaten` tag with the last active
  change, candidates exist for every book (search "nichts" finds none).
- Fast tags and the category column come from `GET /api/config`
  (`services.calibre-hub.fastTags`); toggling them follows in Phase 4.
