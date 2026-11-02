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
CHROMIUM_PATH=$(which chromium) pnpm e2e   # Playwright smoke test against the mocks, desktop + phone
```

Don't start a local calibre-server for development: calibre allows one
program per user and that blocks calibre Desktop.

`nix build .#frontend` builds `dist/` and runs lint, typecheck and unit
tests. After changing dependencies set `hash = lib.fakeHash` in
`package.nix`, build once and take the reported hash. pnpm in nixpkgs is 11;
the lockfile (v9) works with 10 to 12.

## Design

- Library state lives in the URL (`?q=&kategorie=&tag=&author=&series=&lang=&sort=&order=&page=&book=`),
  plain query strings with repeated `tag`. Pages of 60 instead of infinite
  scroll (one redraw per page on E-Ink).
- Desktop (≥ 1024 px): sidebar with fast tags, category tree, authors,
  series, tags, languages; book detail as a side panel (`?book=`). Smaller
  screens: sidebar as drawer, detail as its own view. `/books/:id` is a
  permanent link.
- Search in the header is live (300 ms). Command palette with Ctrl+K or `/`:
  books, authors, series, tags, categories, commands; prefixes `a ` author,
  `s ` series, `t ` tag, `k ` category, `b ` books, `>` commands.
- Themes: system, light, dark, E-Ink (black on white, no animations, larger
  targets), stored per device. Boox/Onyx user agents get a one-time prompt.
- Fast tags and the category column come from `GET /api/config`
  (`services.calibre-hub.fastTags`); toggling them follows in Phase 4.
