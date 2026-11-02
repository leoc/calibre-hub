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
  books, `>` commands) hands over to the palette, as do the command button,
  Ctrl+K and `/`. Narrow screens open the palette full screen from the
  search bar, with scope chips instead of typed prefixes.
- Themes: system, light, dark, E-Ink (black on white, no animations, larger
  targets), stored per device. Boox/Onyx user agents get a one-time prompt.
- Fast tags and the category column come from `GET /api/config`
  (`services.calibre-hub.fastTags`); toggling them follows in Phase 4.
