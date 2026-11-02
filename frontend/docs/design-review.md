# Design review

Two design runs against the MSW mocks (`pnpm dev:mock`), screenshots of
every page and state taken with Playwright and the system chromium.
Priorities: hoch (broken or unusable), mittel (clearly worse than it should
be), niedrig (polish). Status: umgesetzt (done in this change) or offen
(follow-up).

States covered in both runs: login (empty, wrong password, rate limit),
library grid and list (default, filtered with chips, empty result, loading,
502, many pages), sidebar (category tree with "Ohne Kategorie", long author
and tag lists with filter, theme switch), book detail (side panel, phone
page, no cover), edit form (all fields, validation, conflict, cover editor
with search hits, suggestion lists), delete dialog, upload (drop overlay,
confirm dialog, tray with done/duplicate/error), bulk (selection, dialog,
confirm > 50, progress, errors), trash (with restore, empty), command
palette (empty, text, scope chips), E-Ink prompt, and after the rebase the
category suggestions page and the suggestion box in the detail (#8416).

## Run 1: Desktop (#8409)

1400×900 and 1024×768, light and dark.

| ID | Page / state | Finding | Priority | Status |
|---|---|---|---|---|
| D1 | Detail and edit in the side panel | The close button overlaps the title field, the conflict box and long titles, and scrolls away with the content. Now a fixed bar at the top of the sheet holds the close button; the content scrolls below it. | hoch | umgesetzt |
| D2 | Edit form in the side panel | The sticky save bar floats 24 px above the bottom edge (sheet padding), form content shows below it. Panel without bottom padding, bar flush. | hoch | umgesetzt |
| D3 | Bulk bar | Wraps at 1400 and 1024 px; the "Auswahl beenden" X ends up alone on a second line. Now two groups (selection with X first, actions), side by side from xl, otherwise two rows. | hoch | umgesetzt |
| D4 | Bulk job result | "400 geändert, 4 Fehler" counts the failed books as changed; check icon even with errors. Count is done − errors, alert icon on errors. | mittel | umgesetzt |
| D5 | Bulk bar | "Alle N Treffer" is aria-pressed but looks the same pressed or not. Secondary variant when pressed. | mittel | umgesetzt |
| D6 | Header | Upload and logout sit right after the search field in the middle of the header; search not aligned with the content column. Actions to the right edge, logo column as wide as the sidebar. | mittel | umgesetzt |
| D7 | Book detail | Edit/Leseliste/Löschen come before the download (the primary action), Löschen looks like the others. Downloads first; Löschen in the destructive colour. | mittel | umgesetzt |
| D8 | Dark mode | Native controls stay light: date picker icon nearly invisible, white checkboxes, light select popup. `color-scheme: dark`, `accent-color`. | mittel | umgesetzt |
| D9 | Edit form, empty title | Save is disabled without a reason; the field looks valid. Red border plus message "Ohne Titel lässt sich das Buch nicht speichern." | mittel | umgesetzt |
| D10 | Upload tray | "3 Upload(s) fertig" also when two failed; "Trotzdem als neues Buch" is the primary (black) button, more prominent than adding the format; no hint that the header collapses. Summary "1 fertig, 2 mit Problemen", outline button, chevron. | mittel | umgesetzt |
| D11 | Cover editor | URL and search rows: 32 px input next to a 36 px button; hit labels 10 px and cut off. Same height, 12 px labels on two lines. | mittel | umgesetzt |
| D12 | Library, first load | Only "Lädt …" text, the page jumps when the grid arrives. Skeleton grid/list in the same layout (plain text in E-Ink). | mittel | umgesetzt |
| D13 | Library, 502 | One line of text, no explanation. Icon, hint that the hub runs but calibre-server does not answer, retry with icon. | mittel | umgesetzt |
| D14 | Upload button | Keyboard focus on the hidden file input is invisible. Focus ring on the label. | mittel | umgesetzt |
| D15 | Empty result | "Filter zurücksetzen" is a bare underlined link. Outline button. | niedrig | umgesetzt |
| D16 | Sidebar, expanded list | Sorted as strings ("Nummer 1, 10, 100"). Natural sort. | niedrig | umgesetzt |
| D17 | Dialogs | Long titles can run under the close button. Title keeps clear of it. | niedrig | umgesetzt |
| D18 | Empty result | "0 Bücher" in the toolbar and "Keine Bücher gefunden." below say the same twice. | niedrig | offen |
| D19 | Sidebar while loading | "Ohne Kategorie" appears only once its count has loaded, the tree jumps down. | niedrig | offen |
| D20 | List view | No column headers for series, category and date. | niedrig | offen |
| D21 | Palette | Book rows (24 px cover) and other rows (16 px icon) start their text at different x. | niedrig | offen |
| D22 | Side panel on open | The close button gets a visible focus ring right away (Radix autofocus). Focus could go to the heading instead. | niedrig | offen |
| D23 | Grid, selection mode | The selection ring sits tight on the title text. | niedrig | offen |
| D24 | Header | The palette hint shows "⌘ K" on Linux and Windows too. | niedrig | offen |
| D25 | Grid at 1024 px | Only four large columns next to the sidebar. | niedrig | offen |
| D26 | Pagination | Only below the grid; on page 4 of 7 the way on is a long scroll. | niedrig | offen |

## Run 2: Phone and E-Ink (#8410)

Pixel 7 (412×915), small phone 360×740, landscape Pixel 7, E-Ink mode
(`hub.theme=eink`) at Boox size 1072×1448 with a Boox user agent.

| ID | Page / state | Finding | Priority | Status |
|---|---|---|---|---|
| M1 | Palette, drawer, dialogs | Android Back leaves the page (or the app) instead of closing the open overlay. Overlays now own a history entry (`src/lib/back-to-close.ts`); Back closes them, closing them otherwise removes the entry, links in the drawer replace it. Not for the desktop detail panel, which already has `?book=`. Spec: `e2e/back-button.spec.ts`. | hoch | umgesetzt |
| M2 | Library toolbar, phone | "Auswählen" is icon-only on phones and has no accessible name. aria-label and title. | hoch | umgesetzt |
| M3 | All pages, phone | Tap targets far below 44 px: sidebar rows 28 px, tree chevrons 28, list filter 28, buttons 32–36, chip remove 18, stars 28, search clear 28, palette close 36, tray row X 22. New `touch:` variant (`pointer: coarse`) gives them 44 px, the same places E-Ink already enlarges. | hoch | umgesetzt |
| M4 | E-Ink, search and filter fields | Placeholders are grey ("Suchen …", "Filtern …"). Black italic. | hoch | umgesetzt |
| M5 | E-Ink, disabled buttons | Disabled buttons (Speichern, Ausgewählte annehmen) turn grey through opacity. White with a dashed border instead. | hoch | umgesetzt |
| M6 | E-Ink, tap targets | Below 44 px: filter chips (inline link 21 px high), logo link, palette button 40, author/series/tag/language/breadcrumb links in the detail, chip remove, combobox clear, stars, "Filter zurücksetzen". Fixed; `e2e/eink-targets.spec.ts` fails on any visible interactive element under 44×44 on the library, list and selection mode, detail and edit form, palette, suggestions, trash and login. | hoch | umgesetzt |
| M7 | Dialogs on phones | Centered at 10 % from the top: buttons out of thumb reach, no maximum height. Bottom sheet on phones (rounded top, safe-area padding, scrolls inside), centered dialog from 640 px. | mittel | umgesetzt |
| M8 | Safe areas | `viewport-fit=cover` is set, but header, palette, drawer, sticky save and bulk bars and the upload tray ignore the insets (status bar in the installed app, notch in landscape). | mittel | umgesetzt |
| M9 | Bulk bar on phones | Wraps into three to four rows that cover most books. Two rows that scroll sideways (D3). | mittel | umgesetzt |
| M10 | Sidebar filter on phones | 14 px font: iOS zooms in on focus. 16 px on touch screens. | mittel | umgesetzt |
| M11 | E-Ink dialogs | With the transparent overlay a dialog barely stands out from the page. 3 px border. | mittel | umgesetzt |
| M12 | Fast-tag toggles on covers, phone | 22 px. Now 36 px on touch screens (44 in E-Ink); 44 would cover a third of a 110 px cover. Better: a long-press menu or the toggle below the cover. | mittel | offen |
| M13 | Library toolbar, phone | With 44 px controls the view switch wraps to a second line (360 and 412 px). Could move into a menu or next to the count. | niedrig | offen |
| M14 | Suggestions page, phone | "Ausgewählte annehmen" sits at the top, out of thumb reach once the list is long; could join a sticky bottom bar like the bulk bar. | niedrig | offen |
| M15 | Trash, restore notice | On narrow screens the icon wraps onto its own line. Icon and text side by side. | niedrig | umgesetzt |
| M16 | Book detail, phone | The cover takes most of the first screen on 360×740, the download button sits at the fold. A smaller cover next to the title would bring the actions up. | niedrig | offen |
| M17 | E-Ink, motion | Checked: transitions, the chevron rotation, the dialog fade, the skeleton pulse and spinners are off (global rule in `index.css`, skeleton hidden in E-Ink). Nothing slips through. | – | umgesetzt |
| M18 | E-Ink, contrast | Checked: text, borders and icons are pure black on white; the only grey is in covers (grayscale filter on purpose). | – | umgesetzt |

## Counts

| Run | hoch | mittel | niedrig | umgesetzt | offen |
|---|---|---|---|---|---|
| Desktop | 3 | 11 | 12 | 17 | 9 |
| Phone and E-Ink | 6 | 6 | 4 | 12 (+2 checks) | 4 |
