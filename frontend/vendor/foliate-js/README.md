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

Update: copy the same files from a newer commit, apply the `pdf.js` change
again, bump `pdfjs-dist` to the version its `vendor/pdfjs` has, and change
the commit above.
