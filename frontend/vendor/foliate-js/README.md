# foliate-js (vendored)

E-book renderer of the reader (`/read/:id`), from
<https://github.com/johnfactotum/foliate-js>, MIT (see `LICENSE`).

- Commit `78914aef4466eb960965702401634c2cb348e9b1` (2026-05-01, "Use
  original hrefs for external links and add isExternal in fb2.js (#129)").
- Only the modules `view.js` loads: `view.js`, `epub.js`, `epubcfi.js`,
  `mobi.js`, `comic-book.js`, `fb2.js`, `fixed-layout.js`, `paginator.js`,
  `pdf.js`, `progress.js`, `overlayer.js`, `text-walker.js`, `search.js`,
  `tts.js`, and from `vendor/` the bundled `zip.js` (zip.js, BSD-3-Clause)
  and `fflate.js` (MIT) as they are in that commit.
- Changed: `pdf.js` imports pdf.js from the `pdfjs-dist` npm package
  (5.5.207, the version foliate-js bundles) instead of `vendor/pdfjs/`, and
  the two layer stylesheets (`vendor/pdfjs/*.css`, Apache-2.0, from pdf.js
  5.5.207) with `?raw`; without the `cmaps/` and `standard_fonts/` copies
  (PDFs with non-embedded CJK or standard fonts fall back to system fonts).
- Changed: `pdf.js` takes the `legacy` build of `pdfjs-dist` and its worker:
  the modern build calls `Math.sumPrecise`, `Map#getOrInsertComputed`,
  `Uint8Array.fromBase64` and more without a check, which Safari on an iPhone
  and the WebViews of older Boox devices don't have; the legacy build brings
  them along (core-js). `answer()` gives the worker 30 s for each of its
  answers before the first page: what fails in a worker can stay silent, and
  the reader would say it is loading for good. It rejects with the name
  `PDFTimeout`, which the reader says in German.
- Changed: for Safari below 16.4, `paginator.js` has no regex lookbehind (a
  syntax error there, the whole module would fail) and `fixed-layout.js` a
  style element instead of `new CSSStyleSheet()`. `DecompressionStream` for
  zip.js comes from `src/lib/polyfills.ts`. PDFs stay at 16.4: pdf.js' legacy
  build and worker have class static blocks, a syntax error before that; the
  reader then says so.
- Changed (security, review #8411 K1): books render in `blob:` iframes with
  the app's origin, so a script in a book would act with the user's session.
  `book-security.js` (new, not upstream) holds three lines of defence:
  - The sandbox (`bookSandbox()`, used by `paginator.js` and
    `fixed-layout.js`): `allow-same-origin` only (foliate needs the same
    origin to reach the document, not scripts). On WebKit (`isWebKit()`:
    Safari, every browser on iOS/iPadOS, other WebKit browsers) also
    `allow-scripts`, because WebKit fires no events in frames without it
    (<https://bugs.webkit.org/show_bug.cgi?id=218086>): no keys, taps or
    swipes inside the page. Upstream always allows scripts for that reason.
  - `stripScripts()`: removes script elements, `on*` attributes,
    `javascript:` URLs and meta refresh.
  - `addBookCSP()` / `BOOK_CSP_META`: a `<meta http-equiv=
    "Content-Security-Policy">` with `script-src 'none'` first in the head
    of every book document, so scripts stay blocked in a frame that allows
    them even where a browser doesn't hand the app's policy on to `blob:`
    documents. SVG-only documents can't carry it (lines 1, 2 and the
    inherited policy remain).
  - Called in `epub.js` (`Loader#loadReplaced`, `protectDocument()` before
    resources are loaded), `mobi.js` (MOBI6 and KF8 sections, before
    serializing); the generated pages of `fb2.js`, `comic-book.js` and
    `pdf.js` get `BOOK_CSP_META` in their templates.
  - `epub.js` `Loader#loadItem`: script files of a book are not loaded
    (`allow` starts as `false` for them).
  - The hub's own Content-Security-Policy (`script-src 'self'`) applies to
    the blob documents too where the browser passes it on (Chromium does,
    `e2e/book-csp.spec.ts`).

Update: copy the same files from a newer commit, apply the changes above
again, bump `pdfjs-dist` to the version its `vendor/pdfjs` has, and change
the commit above.
