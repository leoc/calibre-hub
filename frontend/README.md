# calibre-hub web app

Vite + React + TypeScript, TanStack Router and Query, shadcn/ui-style
components on Tailwind 4. Static build, served by the hub
(`CALIBRE_HUB_FRONTEND`, SPA fallback). UI texts are German
(`src/i18n/de.ts`; another language is a file with the same keys).

## Development

```sh
pnpm install
pnpm dev          # proxies /api to https://hub.nor.sh (HUB_URL=… to change), log in with the real user
pnpm dev:mock     # MSW mock library (400 books, VITE_MOCK_BOOKS=10000 for more), password "hub"; ?scenario=voll|analyse|leer|dubletten|rechte for the Eingang
pnpm test         # vitest
pnpm lint && pnpm typecheck
CHROMIUM_PATH=$(which chromium) pnpm e2e   # Playwright against the mocks: *.spec.ts and the Gherkin scenarios in e2e/features (playwright-bdd), desktop + phone
HUB_CSP=1 CHROMIUM_PATH=$(which chromium) pnpm e2e   # the same under the hub's Content-Security-Policy; violations print as "CSP violation"
```

The hub sends a Content-Security-Policy (`src/calibre_hub/security_headers.cr`):
scripts only from the app's own files, so no inline scripts in `index.html`
(the theme script is `public/theme-init.js`), no `eval` (zod runs
`jitless`), and the reader's book pages can't run scripts. `HUB_CSP=1`
makes the dev server send the same policy.

### Reader in Safari

`pnpm e2e` doesn't take WebKit: nixpkgs' Playwright browsers are older than
the npm package and don't work with it, and its own build wants some 80
Ubuntu libraries. So the e2e tests take Chromium for WebKit
(`e2e/features/reading.feature`, Safari's `GestureEvent`), and
`e2e/webkit/run.sh` opens an EPUB and a PDF in a real WebKit as an iPhone,
with nixpkgs' Playwright, under the hub's policy (`HUB_CSP=1`), and again
with what iOS below 16.4 lacks taken away. Chromium doesn't see what WebKit
does with that policy, so run it after changes to the reader, the policy or
`vendor/foliate-js`.

That WebKit is not Safari on a phone. After changes to the reader or
`vendor/foliate-js/book-security.js`, check once in Safari (Mac, iPhone or
iPad) on the deployed hub with `e2e/fixtures/script.epub` uploaded as a book:

- the book opens, arrow keys (Mac) and swipes/taps (iPhone, iPad) turn
  pages, E-Ink tap zones work
- Web Inspector → the book's frame: `sandbox="allow-same-origin
  allow-scripts"`, a `Content-Security-Policy` meta first in its head, no
  `<script>`, no `on…` attributes
- the console of the app: no `pwned` in localStorage, no request to
  `/api/pwned` in the network tab (only CSP reports, if any)
- delete the test book afterwards

Don't start a calibre-server by hand for development: calibre allows one
program per user and that blocks calibre Desktop. `dev/up` runs it in a sandbox
as a user of its own (README, Development).

`nix build .#frontend` builds `dist/` and runs lint, typecheck and unit
tests. After changing dependencies set `hash = lib.fakeHash` in
`package.nix`, build once and take the reported hash. pnpm in nixpkgs is 11;
the lockfile (v9) works with 10 to 12.

## Design

- Library state lives in the URL (`?q=&kategorie=&unsorted=&tag=&author=&series=&lang=&list=&listPath=&listOwner=&direct=&sort=&order=&page=&book=`),
  plain query strings with repeated `tag`. Pages of 60 instead of infinite
  scroll (one redraw per page on E-Ink).
- Categories are shown and typed as paths (`Sachbuch/Geschichte`) but stored,
  in URLs and the API, with dots as calibre does (`src/lib/kategorie.ts`).
  `?unsorted` lists books without a category (`#kategorie:false`); saving a
  category there opens the next one in the form.
- Desktop (≥ 1024 px): sidebar with reading lists, category tree, authors,
  series, tags, languages; book detail as a side panel (`?book=`). Smaller
  screens: sidebar as drawer, detail as its own view. `/books/:id` is a
  permanent link.
- Search and command palette, specified in `e2e/features/search.feature`:
  wide screens (≥ 640 px) search the library live from the header; a prefix
  at the start (`a ` author, `s ` series, `t ` tag, `k ` category, `l `
  lists, `b ` books, `>` commands) hands over to the palette, as do the command button
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
    trash, `gm` metadata, `gv` suggestions, `gL` lists, `gD` duplicates, `gc` category tree (j/k move,
    l/h open and close, Enter filters, Escape back to the books), `f`/`F`
    hints (letters on every book and link; `f` opens, `F` selects a book or
    opens a link in a new tab), and on the active book `e` edit, `t`
    default reading list, `dd` delete, `y` copy its link, `D`
    download the first format.
  - Both modes: `s` (App: Ctrl+S, the browser's "save page" never opens)
    puts the selection, or else the active book, into the list used last,
    or takes them out again when all are in it already (with the undo
    toast); without a list used last it opens "In Listen speichern". `S`
    (App: Ctrl+Shift+S) opens that dialog for the active book. Visual mode, a pending count or sequence
    and messages show top right.
  - In the open detail j/k (arrows) go to the next/previous book. `/` puts
    the focus into the wide search bar (phones: the palette); Enter
    searches and goes on in the list from the first result, Escape returns
    to the list. `>` opens the palette's commands, with the commands on
    the selection or the active book ("Tag hinzufügen (3)", see "Commands
    on books"). Selection uses the bulk store and turns selection mode on.
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
    saveLast saveDialog delete copyLink download back forward goLibrary
    goTrash goMetadata goSuggestions goCategories goLists goDuplicates hints
    hintsSelect help`. Example:
    `{"down": ["n", "j", "<Down>"], "toggleList": []}`.
- Commands on books (`e2e/features/keyboard.feature`, Phase 3): one list
  of definitions in `src/lib/book-actions.ts` (name, icon, typed keywords,
  the kind of value, which books they are offered for, the bulk change
  they make), used by the bulk bar (its buttons and dialogs) and the
  palette; `src/lib/run-action.ts` runs them, `src/lib/jobs.ts` and
  `src/components/job-watcher.tsx` follow the hub's jobs to the toast.
  - Target (`src/lib/use-action-target.ts`): the selection (ids in the
    order they were selected, or "Alle N Treffer" as a query), else the
    active book (focus ring), else the book open in the detail. The
    command names it: "Tag hinzufügen (3)", "Tag hinzufügen: <Titel>".
  - Input: direct, a keyword and the value (`> tag sheet music` offers
    "Tag ‚Sheet Music‘ hinzufügen (3)", existing values first, then "Neu:
    …" for a new one); or two steps: `> Tag hinzufügen`, Enter, then the
    palette lists the values (categories as an indented tree, "Kategorie
    entfernen" and the like at the end; Backspace in the empty input or
    the arrow goes back). Keywords: `tag`, `tag entfernen`, `kategorie`,
    `serie`, `nummerieren`, `autor`, `verlag`, `sprache`, `bewertung`,
    `jahr`, `zu liste`, `aus liste`, `neue liste`.
  - Edit: tags add/remove, Kategorie, Serie (and "setzen und
    durchnummerieren" in selection order, ids only), Autor (`A & B` for
    several), Verlag, Sprache, Bewertung, Erscheinungsjahr (month and day
    stay). They run as a bulk job at once; the toast "Erledigt: …" offers
    "Rückgängig" (`POST /api/jobs/:id/undo`, each book's own values).
  - Lists: "Zu Liste …" / "Aus Liste …" with sublists as paths, never a
    magic shelf; toast with "Rückgängig". "Neue Liste aus Auswahl", "Als
    Regal speichern" (magic shelf from the search) as before.
  - Runs: "Metadaten holen und prüfen" (`metadata`), "Kategorie
    vorschlagen" (`classify`), "EPUB reparieren", "Nach EPUB
    konvertieren" (`POST /api/convert` with `books`), "Auf Duplikate
    prüfen" (`/duplicates?ids=…` shows only those books' groups), "Cover
    neu aus der Datei holen" (one request per book).
  - Device and export: "Lesen" (one book), "Herunterladen" (the first
    format, several one after another, no ZIP), "Link kopieren" (one link
    per line), "Offline verfügbar machen", "Löschen".
  - Asks first, in the palette ("Ja, auf 120 Bücher anwenden" /
    "Abbrechen"): deleting, and runs over more than 50 books. The bulk
    bar's dialogs ask the same way.
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
- Reading lists (`e2e/features/lists.feature`), like playlists: the
  sidebar section "Listen" shows the favorites (and the open list) and
  "Alle Listen (N)", the overview `/lists` (palette command "Listen", Vim
  `gL`): every list with covers, description, count and badges, "Öffnen",
  "Bearbeiten", toggles for favorite, sync and default list, "Löschen"
  (asks), and "Neue Liste". A list's page
  is the library with `?list=` (cover mosaic of the books added last,
  description, count, favorite, "Liste bearbeiten" with name, description,
  favorite, default list, sync to the reader, visibility and delete; sorts:
  Zuletzt hinzugefügt, Titel, Autor, Serie). The bookmark on covers and
  list rows saves to the default list; a long press or right click opens
  "In Listen speichern" (a checkbox per list, "Neue Liste" with its name
  typed in place), as does "Speichern" in the detail, which also offers the
  default list and the list used last ("In Urlaub"). Bulk: "Zu Liste",
  "Aus Liste" (in a list: "Aus dieser Liste", no question but a toast "2
  Bücher aus Urlaub entfernt · Rückgängig" for 8 s that puts exactly those
  books back; `src/lib/toast.ts`, one message at a time, no animation). Palette: `l ` lists the
  lists, `> zu liste urlaub` / `> aus liste urlaub` for the selection,
  the active or the open book (see "Commands on books"), "In Listen
  speichern: <Titel>" opens the dialog, `> Neue Liste: Name` (or a new
  name after `l `) creates one (with the selection or the book in it). They replace the fast tags; `fastTags` in `GET /api/config` is
  ignored. The mocks start with "Leseliste" (default, favorite, synced, the
  books tagged `leseliste`), "Urlaub" (favorite, used last, books 11–13)
  and an empty "Klassiker".
- Nested lists: the name is a path, "Urlaub/2026" is the sublist 2026 of
  Urlaub; a level without a list of its own ("Reise" above "Reise/Meer")
  is a folder (`?listPath=Reise`). `src/lib/lists.ts` builds the tree
  (`buildListTree`, per owner, favorites first) and holds the one place
  for shown names (`listLabel` the path, `listLeaf` the last level). The
  sidebar shows favorites as a tree with their sublists (chevrons like the
  category tree), the overview indents sublists and folds them, the palette
  (`l `) offers every level as a path, "In Listen speichern" is a tree with
  "+" for a new sublist under a node. A list's page shows the levels above
  it as links, its books with those of its sublists, and "Nur direkt"
  (`?direct=1`) for its own only; "Aus dieser Liste" is offered only there
  or without sublists. Renaming a list (a new path) takes its sublists along.
- Magic shelves (`e2e/features/shelves.feature`, `src/lib/shelves.ts`,
  `src/components/shelf.tsx`): a list with a `rule` (AND/OR over Tag,
  Kategorie, Autor, Serie, Sprache, Freitext), a saved search shown like a
  list: sidebar (icon `ListFilter`, favorite by default), overview, palette
  `l `, `?list=` with the rule as a line under the name. "Als Regal
  speichern" next to the filter chips (and in the palette) turns the
  library's filters into a rule; "Neues Regal" in the overview and the
  palette starts an empty one; "Regal bearbeiten" edits name, description,
  rule, favorite and visibility. A shelf is never offered to save a book to
  (bookmark, "In Listen speichern", "Zu Liste", `s`), has no sync or default
  list toggles and no "Aus dieser Liste". Counts follow the library:
  `followShelves` reads the lists again after every invalidation of
  `["books"]` or `["categories"]` while a shelf exists. The mocks evaluate
  rules against the mock library (free text like the mock search).

- Reader (`e2e/features/reading.feature`): `/read/:id[?format=]`, full
  screen outside the app shell (own keys, the library's keymap is not
  mounted), lazy-loaded with foliate-js (`vendor/foliate-js`, pinned commit
  in its README) and `pdfjs-dist`. EPUB, KEPUB, AZW3/MOBI, FB2, CBZ, PDF
  (`src/lib/reader.ts`). Table of contents, progress bar with percentage and
  chapter. Settings sheet ("Darstellung", `src/components/reader-settings.tsx`,
  `src/lib/reader-settings.ts`): font (book's, serif, sans, bundled
  @fontsource fonts loaded on demand), size, line height, justification,
  hyphenation, margins, column width, columns, paginated/scrolled,
  animation, colors (Hell, Sepia, Dunkel, E-Ink, independent of the app
  theme), "Buchstil überschreiben"; per account (`/api/reader/settings`),
  applied live, saved 0.6 s after a change; bottom sheet on phones.
  Absolute font sizes in the book's CSS follow the size
  (`--hub-font-scale`). Keys: arrows, PageUp/PageDown, Space/Shift+Space, `j`/`k` (and
  `l`/`h`) in Vim mode, Escape back to the detail. Phones swipe (foliate-js);
  E-Ink: no animation, always paginated, black on white, tap zones (left third back, right
  third on, middle shows the toolbar), no swiping. The position is saved
  1.5 s after a page turn and when leaving, with the device id
  `hub.device` and a name from the user agent (`hub.deviceName`
  overrides it). A book opens where this device stopped; a newer position of
  another device (more than 1 % apart) is offered: "Auf Boox bei 71 % – dort
  weiterlesen?". The detail shows "Lesen" / "Weiterlesen (63 %)", covers in
  grid and list a thin bar (`GET /api/progress`), the palette "Lesen: <Titel>"
  for the open book. The mocks serve every file as a small three-chapter
  EPUB (`src/mocks/fixtures`), PDFs as a three-page PDF.
- Duplicates (`/duplicates`, sidebar entry and palette command "Duplikate",
  Vim `gD`; `e2e/features/duplicates.feature`): the groups of
  `GET /api/duplicates` with their reasons ("Gleiche ISBN …", "Titel und
  Autor (95 %)", "Defekte Datei"), the books side by side (formats with
  sizes, ISBN, publisher, date, language, category, tags, description,
  cover, lists; differing rows bold), a radio "Behalten" per book (the
  hub's suggestion preselected), "Zusammenführen" (asks with the dry run:
  formats, fields, cover, lists, reading position, what goes to the trash)
  and "Keine Duplikate" (toast with "Rückgängig"). After a merge a note
  with "Rückgängig"; "Zuletzt zusammengeführt" lists the merges with undo.
  The threshold select asks the hub again. An upload the hub pairs with
  other books says so with a link to the page. The mocks seed two pairs in
  the middle of the library (ids 150/160: one book twice, the copy with a
  PDF and a publisher; 170/180: a PDF and an 80-byte Anna's Archive
  leftover with the ISBN in its title).
- Offline (`src/lib/offline.ts`, `src/lib/progress-sync.ts`,
  `src/components/offline.tsx`): "Offline verfügbar machen" in the detail
  and the reader's "Darstellung" stores the book's file in Cache Storage
  (`hub-books`, under its download URL) and the book with every device's
  position in `hub.offline`; then "Offline verfügbar · 1,2 MB" and "Offline
  entfernen". The reader takes the file from there first; without network
  (or with the hub out of reach) it opens from what was stored. Positions
  are written to `hub.progressQueue` first and removed once the hub has
  them; what waits is sent on start, on `online` and when the app is shown
  again, with its `age`, so the hub dates it back and the newest position
  still wins. "Offline" in the header and the reader while
  `navigator.onLine` is false; without the hub the error page lists the
  books stored offline. Logging out sends what waits and then deletes all
  of it. The service worker (`src/service-worker.js`, built into
  `dist/sw.js` by the `service-worker` plugin in `vite.config.ts` with the
  list of built files and a hash over them) precaches the whole build,
  answers navigations from the network and falls back to `index.html`
  offline or on 5xx, and never touches `/api/`, `/get/`, `/opds`,
  `/healthz`. It is registered in builds only (dev:mock runs MSW's worker);
  e2e emulates offline with `context.setOffline`, the mocks then fail
  `/api/`.
- The category column comes from `GET /api/config`.
