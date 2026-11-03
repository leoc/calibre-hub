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
- Changed (security, review #8411 K1): books render in `blob:` iframes with
  the app's origin, so a script in a book would act with the user's session.
  - `paginator.js` and `fixed-layout.js`: the iframe sandbox is
    `allow-same-origin` only, without `allow-scripts` (foliate needs the
    same origin to reach the document, not scripts). Upstream allows scripts
    because WebKit fires no events in frames without them
    (<https://bugs.webkit.org/show_bug.cgi?id=218086>): in Safari, keys,
    clicks and swipes inside the page don't reach the reader, turning pages
    there works through the reader's margins and toolbar only.
  - `strip-scripts.js` (new, not upstream): removes script elements, `on*`
    attributes, `javascript:` URLs and meta refresh from a document. Called
    in `epub.js` (`Loader#loadReplaced`, before resources are loaded) and in
    `mobi.js` (MOBI6 and KF8 sections, before serializing).
  - `epub.js` `Loader#loadItem`: script files of a book are not loaded
    (`allow` starts as `false` for them).
  - The hub's Content-Security-Policy (`script-src 'self'`) applies to the
    blob documents too and is the third line.

Update: copy the same files from a newer commit, apply the changes above
again, bump `pdfjs-dist` to the version its `vendor/pdfjs` has, and change
the commit above.
