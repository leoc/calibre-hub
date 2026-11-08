# The Eingang: what the analysis found in the inbox and uploads, before anything
# is in the library, and the four ways out of the list.
#
# The mock hub has nine files like a real inbox (a sure ISBN hit, a
# possible duplicate, a file that failed, ...) and 150 scans, the analysis
# standing at one file with 1,292 still to analyse and 3 proposals for books of
# the library, 1,454 in the Eingang.

Feature: Eingang

  Background:
    Given I am logged in

  Scenario: The page shows the numbers, the bar while it analyses and the proposals
    When I open the Eingang
    Then the line under the title says "1.292 von 1.454 noch zu analysieren"
    And the striped part "Noch zu analysieren: 1.292" stands at 11 percent
    And the row of "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf" shows "98 % · Sicher", then "Functional Analysis" and "Kosaku Yosida"
    And the row of "Stewart Calculus Concepts and Contexts 2nd Edition.pdf" shows "78 % · Dublette?", then "Calculus: Concepts and Contexts" and "James Stewart"
    And a row has no checkbox

  Scenario: The menu leads to the Eingang with its count
    Given I open the library
    When I open the Eingang from the menu
    Then the menu shows "1.454" next to the Eingang

  Scenario: Filtering by kind, then confidence
    When I open the Eingang
    Then the filters come in the order "Art", "Sicherheit"
    And the filter "Sicherheit" offers "Sicher ab 90 (2)"
    When I choose "Sicher ab 90 (2)" in "Sicherheit"
    Then the list has 2 rows
    When I choose "Mögliche Dubletten (1)" in "Art"
    Then the filter "Sicherheit" reads "Alle (1)"
    And the list has 1 rows
    And the filter "Sicherheit" offers "Prüfen (1)"
    And the filter "Sicherheit" offers "Sicher ab 90 (0)"
    And the line under the title says "1.292 von 1.454 noch zu analysieren"

  Scenario: Every number in the filters is what the list then shows, skipped ones included
    Given some files were skipped, a possible and a sure duplicate among them
    When I open the Eingang
    Then the filter "Art" offers "Neue Dateien (156)"
    And the filter "Art" offers "Mögliche Dubletten (0)"
    And the filter "Art" offers "Sichere Dubletten (0)"
    And the filter "Art" offers "Übersprungen (3)"
    And every number in the filters is what the list shows

  Scenario: Every number in the filters holds for a source too
    Given files came in by the inbox and an upload
    When I open the Eingang
    And I choose "Inbox (158)" in "Quelle"
    Then every number in the filters is what the list shows

  Scenario: Übersprungen is always a kind
    When I open the Eingang
    Then the filter "Art" offers "Übersprungen (0)"
    When I choose "Übersprungen (0)" in "Art"
    Then the list says "Hier ist nichts zu entscheiden."

  Scenario: The bars show where everything stands, each entry in one part
    When I open the Eingang
    Then the overview says "Bibliothek 400" and "Eingang 1.454"
    And the overview reads "400 in der Bibliothek, 1.454 im Eingang"
    And the bar's parts are "Neu, sicher: 2", "Neu, prüfen: 2", "Neu, unsicher: 152", "Fehlgeschlagen: 1", "Sichere Dubletten: 1", "Mögliche Dubletten: 1", "Schon in der Bibliothek: 3" and "Noch zu analysieren: 1.292"
    And the legend's rows are "Neu, sicher 2", "Neu, prüfen 2", "Neu, unsicher 152", "Fehlgeschlagen 1", "Sichere Dubletten 1", "Mögliche Dubletten 1", "Übersprungen 0", "Schon in der Bibliothek 3" and "Noch zu analysieren 1.292"
    And the legend's numbers add up to 1454

  Scenario: A skipped entry counts only under Übersprungen
    Given some files were skipped, a possible and a sure duplicate among them
    When I open the Eingang
    Then the bar's parts are "Neu, sicher: 2", "Neu, prüfen: 1", "Neu, unsicher: 152", "Fehlgeschlagen: 1", "Übersprungen: 3", "Schon in der Bibliothek: 3" and "Noch zu analysieren: 1.292"
    And the legend's numbers add up to 1454

  Scenario: Clicking a part filters, the part stays marked, the bar stands still
    When I open the Eingang
    And I press the part "Neu, prüfen: 2"
    Then the filter "Art" reads "Neue Dateien (157)"
    And the filter "Sicherheit" reads "Prüfen (2)"
    And the list has 2 rows
    And the part "Neu, prüfen: 2" is marked without color
    And the legend's row "Neu, prüfen" is marked
    And the bar's parts are "Neu, sicher: 2", "Neu, prüfen: 2", "Neu, unsicher: 152", "Fehlgeschlagen: 1", "Sichere Dubletten: 1", "Mögliche Dubletten: 1", "Schon in der Bibliothek: 3" and "Noch zu analysieren: 1.292"
    When I press the part "Sichere Dubletten: 1"
    Then the filter "Art" reads "Sichere Dubletten (1)"
    And the filter "Sicherheit" reads "Alle (1)"
    And the part "Neu, prüfen: 2" is not marked
    When I press the part "Schon in der Bibliothek: 3"
    Then the list has 3 rows
    And the part "Schon in der Bibliothek: 3" is marked without color

  Scenario: The legend's rows filter too, a part at 0 as well
    When I open the Eingang
    And I press the legend's row "Mögliche Dubletten"
    Then the filter "Art" reads "Mögliche Dubletten (1)"
    And the list has 1 rows
    When I press the legend's row "Übersprungen"
    Then the filter "Art" reads "Übersprungen (0)"
    And the legend's row "Übersprungen" is marked

  Scenario: What isn't analysed yet leads nowhere in the bar, in the legend back to all
    When I open the Eingang
    And I press the part "Sichere Dubletten: 1"
    Then there is no button "Noch zu analysieren: 1.292"
    When I press the legend's row "Noch zu analysieren"
    Then the filter "Art" reads "Alle (159)"

  Scenario: A tiny part keeps its width, each part is a real button
    When I open the Eingang
    Then the part "Sichere Dubletten: 1" is at least 8 px wide
    When I focus the part "Sichere Dubletten: 1" and press "Enter"
    Then the filter "Art" reads "Sichere Dubletten (1)"

  Scenario: With the analysis through there is no striped part, the line says so
    Given the analysis is "idle"
    When I open the Eingang
    Then the line under the title says "162 Dateien warten auf dich, alle analysiert"
    And no part is striped
    And the legend has no row "Noch zu analysieren"
    And the legend's numbers add up to 162

  Scenario: A source shows only its files, the overview stays whole
    Given files came in by the inbox and an upload
    When I open the Eingang
    And I choose "Upload (1)" in "Quelle"
    Then the bar's parts are "Neu, sicher: 1"
    And the legend has no row "Schon in der Bibliothek"
    And the legend has no row "Noch zu analysieren"
    And the overview says "Bibliothek 400" and "Eingang 1.454"
    And the legend's numbers add up to 1

  Scenario: The library's books have no source, going there leaves the source
    Given files came in by the inbox and an upload
    When I open the Eingang
    And I choose "Upload (1)" in "Quelle"
    And I choose "Schon in der Bibliothek (3)" in "Art"
    Then there is no filter "Quelle"
    When I choose "Neue Dateien (157)" in "Art"
    Then the filter "Quelle" reads "Alle"
    And the list has 100 rows

  Scenario: Only Neu sicher and the sure duplicates have a bulk
    When I open the Eingang
    Then the page has no bulk
    When I choose "Neue Dateien (157)" in "Art"
    Then the page has no bulk
    When I choose "Prüfen (2)" in "Sicherheit"
    Then the page has no bulk
    When I choose "Mögliche Dubletten (1)" in "Art"
    Then the page has no bulk
    When I choose "Schon in der Bibliothek (3)" in "Art"
    Then the page has no bulk
    When I press the part "Neu, sicher: 2"
    Then the button "Alle 2 übernehmen" is enabled
    When I press the part "Sichere Dubletten: 1"
    Then the button "Alle 1 in den Papierkorb" is enabled

  @narrow
  Scenario: On a phone Art and Sicherheit have the full width, the legend's rows are the target
    When I open the Eingang
    Then the filters "Art" and "Sicherheit" have a line each
    And each row of the legend is at least 44 px high

  @narrow
  Scenario: At 320 px nothing scrolls sideways
    Given the screen is 320 px wide
    When I open the Eingang
    Then the page is no wider than the screen
    When I press the part "Neu, sicher: 2"
    Then the page is no wider than the screen

  Scenario: The list loads more on request
    When I open the Eingang
    Then the list has 100 rows
    When I press the button "Mehr anzeigen"
    Then the list has 159 rows

  Scenario: The surest come first, ties by path, a failed file last, over the pages too
    When I open the Eingang
    Then the rows start with "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf", "Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf" and "Birds.pdf"
    And the page has no sort control
    When I press the button "Mehr anzeigen"
    Then the rows end with "scan-150.pdf", "1380293052863.pdf" and "kaputt.pdf"

  Scenario: The drawer shows everything found about a file
    When I open the Eingang
    And I open the row "Functional Analysis"
    Then the drawer's header reads "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf"
    And the drawer shows the folder "Defaults"
    And the drawer shows "98 % · Sicher" and "ISBN im Buch, Katalog passt"
    And the candidates are "Functional Analysis" from "Open Library" at "98 %" and "Functional Analysis" from "Dateiname" at "80 %"
    And the row "Functional Analysis" is marked as the current one

  Scenario: A file in the root has no folder, a duplicate says of what
    When I open the Eingang
    And I open the row "Britannica Illustrated Science Library: Birds"
    Then the drawer shows no folder
    And the drawer shows "ISBN 9781593394523 steht auch bei #7, #8: Dublette oder Fehler?"
    When I press "Escape"
    And I open the row "Calculus: Concepts and Contexts"
    Then the drawer shows "Mögliche Dublette von „Calculus: Concepts and Contexts“ in der Bibliothek."

  @wide
  Scenario: Moving through the list by key, the list staying in sight
    When I open the Eingang
    And I open the row "Britannica Illustrated Science Library: Birds"
    And I press "j"
    Then the drawer's header reads "Stem Cells - From Bench to Bedside.pdf"
    And the row "Stem Cells - From Bench to Bedside.pdf" is marked as the current one
    When I press "k"
    Then the drawer's header reads "Birds.pdf"
    And each candidate has its digit
    When I press "j" 19 times
    Then the drawer's header reads "scan-015.pdf"
    And the row "scan-015" is in view
    When I press "Escape"
    Then no drawer is open

  @wide
  Scenario: A click beside the drawer closes it, nothing dims the list
    When I open the Eingang
    And I open the row "Functional Analysis"
    Then the list behind the drawer isn't dimmed
    When I click beside the drawer
    Then no drawer is open

  Scenario: Check and trash on a row decide at once
    When I open the Eingang
    Then the row "Functional Analysis" has the icons "Übernehmen" and "Papierkorb" at 36 px
    When I press "Übernehmen" on the row "Functional Analysis"
    Then the row "Functional Analysis" is gone
    And the hub was asked to "accept" 1 entry
    When I press "Papierkorb" on the row "Basic Pathology"
    Then the row "Basic Pathology" is gone
    And no dialog asks anything
    And the hub was asked to "trash" 1 entry
    And the line under the title says "1.292 von 1.452 noch zu analysieren"

  Scenario: Accepting everything sure asks nothing
    When I open the Eingang
    And I press the part "Neu, sicher: 2"
    And I press the button "Alle 2 übernehmen"
    Then no dialog asks anything
    And the hub was asked to "accept" 2 entries
    And the hub was told to expect 2
    And the list says "Hier ist nichts zu entscheiden."
    And the page has no bulk
    And the legend's row "Neu, sicher" reads "Neu, sicher 0"

  Scenario: A row that may be a duplicate says of what and stays out of a bulk
    When I open the Eingang
    And I choose "Mögliche Dubletten (1)" in "Art"
    Then the row "Stem Cells: From Bench to Bedside" says "Dublette von „Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf“ im Eingang"
    And the list has 1 rows
    And the page has no bulk
    When I choose "Sichere Dubletten (1)" in "Art"
    Then the row "Calculus: Concepts and Contexts" links "Calculus: Concepts and Contexts" to book 1 after "Dublette von"

  Scenario: A failed file has no proposal to accept
    When I open the Eingang
    And I choose "Fehlgeschlagen (1)" in "Sicherheit"
    Then the row "kaputt.pdf" can't be accepted
    And the page has no bulk

  @wide
  Scenario: The drawer's four exits with their keys, the next entry opening
    When I open the Eingang
    And I open the row "Mathematics of the Discrete Fourier Transform"
    Then the drawer has the buttons "Übernehmen a", "Wie in der Datei f", "Überspringen j" and "Papierkorb d"
    And the button "Papierkorb d" is outlined in red
    And the drawer shows "k zurück · e bearbeiten · Esc schließen"
    When I press "a"
    Then the hub was asked to "accept" 1 entry
    And the drawer's header reads "scan-001.pdf"
    When I press "f"
    Then the hub was asked to "file" 1 entry
    And the drawer's header reads "scan-002.pdf"
    When I press "d"
    Then the hub was asked to "trash" 1 entry
    And the drawer's header reads "scan-003.pdf"
    And no dialog asks anything

  @wide
  Scenario: Keys leave modifiers and held keys alone
    When I open the Eingang
    And I open the row "Mathematics of the Discrete Fourier Transform"
    And I press "Control+a"
    And I hold "a" down
    Then the hub was asked to "accept" 1 entry
    And the drawer's header reads "scan-001.pdf"

  @wide
  Scenario: Skipping marks the entry and moves on, back changes nothing
    When I open the Eingang
    And I open the row "Britannica Illustrated Science Library: Birds"
    And I press "j"
    Then the hub was asked to "skip" 1 entry
    And the drawer's header reads "Stem Cells - From Bench to Bedside.pdf"
    And the row "Britannica Illustrated Science Library: Birds" says "Übersprungen"
    When I press "k"
    Then the drawer's header reads "Birds.pdf"
    And the hub was asked to "skip" 1 entry
    When I press "Escape"
    Then the filter "Art" offers "Neue Dateien (156)"
    When I choose "Neue Dateien (156)" in "Art"
    Then the row "Britannica Illustrated Science Library: Birds" is gone
    When I choose "Übersprungen (1)" in "Art"
    Then the list has 1 rows
    When I open the row "Britannica Illustrated Science Library: Birds"
    And I press the button "Wieder aufnehmen"
    Then the hub was asked to "unskip" 1 entry
    And the list says "Hier ist nichts zu entscheiden."

  @wide
  Scenario: Editing before accepting, typing decides nothing
    When I open the Eingang
    And I open the row "Functional Analysis"
    And I press "e"
    And I type "Funktionalanalysis" as the title
    Then the hub wasn't asked anything
    When I press "Enter"
    Then the hub was asked to accept the title "Funktionalanalysis" by "Kosaku Yosida"
    And the drawer's header reads "Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf"

  Scenario: A decision that failed comes back with its reason
    When I open the Eingang
    And I choose "Fehlgeschlagen (1)" in "Sicherheit"
    And I press "Papierkorb" on the row "kaputt.pdf"
    Then the row "kaputt.pdf" says "Das hat nicht geklappt: calibre kann die Datei nicht lesen"

  Scenario: An accepted book that comes back as a duplicate, without an error, is in the list again
    Given decisions can come back
    When I open the Eingang
    And I press "Übernehmen" on the row "Mathematics of the Discrete Fourier Transform"
    Then the row "Mathematics of the Discrete Fourier Transform" links "Dune" to book 1 after "Dublette von"
    And every number in the filters is what the list shows

  Scenario: What came back is in the list of its new kind too
    Given decisions can come back
    When I open the Eingang
    And I choose "Mögliche Dubletten (1)" in "Art"
    And I choose "Neue Dateien (157)" in "Art"
    And I press "Übernehmen" on the row "Mathematics of the Discrete Fourier Transform"
    Then the filter "Art" reads "Neue Dateien (156)"
    When I choose "Mögliche Dubletten (2)" in "Art"
    Then the list has 2 rows
    And every number in the filters is what the list shows

  Scenario: A decision that fails the same way twice is back both times
    Given decisions can come back
    When I open the Eingang
    And I press "Übernehmen" on the row "Birds"
    Then the row "Birds.pdf" says "Das hat nicht geklappt: calibre kann die Datei nicht lesen"
    When I press "Übernehmen" on the row "Birds"
    Then the row "Birds.pdf" says "Das hat nicht geklappt: calibre kann die Datei nicht lesen"

  Scenario: The thresholds hide behind one button, a line per source
    When I open the Eingang
    Then the button "Automatisch übernehmen: Inbox ab 90 %, Upload ab 90 %" is enabled
    When I press the button "Automatisch übernehmen: Inbox ab 90 %, Upload ab 90 %"
    And I set "Inbox: ab Sicherheit (60 bis 100)" to "59"
    Then the dialog's "Speichern" is disabled
    When I set "Inbox: ab Sicherheit (60 bis 100)" to "95"
    And I switch off "Upload"
    And I press the dialog's "Speichern"
    Then the button "Automatisch übernehmen: Inbox ab 95 %, Upload aus" is enabled
    When I press the button "Automatisch übernehmen: Inbox ab 95 %, Upload aus"
    And I set "Inbox: ab Sicherheit (60 bis 100)" to "90"
    And I switch on "Upload"
    And I press the dialog's "Speichern"
    Then the button "Automatisch übernehmen: Inbox ab 90 %, Upload ab 90 %" is enabled

  @narrow
  Scenario: On a phone the thresholds' button stays within the page
    When I open the Eingang
    Then the page is no wider than the screen

  Scenario: With one source there is nothing to say about it
    When I open the Eingang
    Then there is no filter "Quelle"
    And the row of "Birds.pdf" shows no source

  Scenario: With several sources the rows say which and a filter chooses
    Given files came in by the inbox and an upload
    When I open the Eingang
    Then the filter "Quelle" offers "Inbox (158)"
    And the filter "Quelle" offers "Upload (1)"
    And the row of "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf" shows the source "Upload"
    When I choose "Upload (1)" in "Quelle"
    Then the list has 1 rows
    When I press the part "Neu, sicher: 1"
    Then the button "Alle 1 übernehmen" is enabled
    When I press the button "Alle 1 übernehmen"
    Then the hub was asked to accept the filter of the source "upload"

  Scenario: A row from the days of the backlog lists and decides, no source to name
    Given a row from the days of the backlog is still there
    And files came in by the inbox and an upload
    When I open the Eingang
    Then the filter "Quelle" offers "Inbox (157)"
    And the filter "Quelle" offers "Upload (1)"
    And the row of "Robbins - Basic Pathology 8e.chm" shows no source
    When I press "Übernehmen" on the row "Basic Pathology"
    Then the row "Basic Pathology" is gone
    And the hub was asked to "accept" 1 entry

  Scenario: Nothing while the analysis runs normally
    When I open the Eingang
    Then the page says nothing about the analysis

  @narrow
  Scenario: On a phone the confidence is a ring
    When I open the Eingang
    Then the row "Functional Analysis" shows the ring "98 %, Sicher" in rgb(21, 128, 61) at 24 px
    And the row "Basic Pathology" shows the ring "70 %, Prüfen" in rgb(180, 83, 9) at 24 px
    And the row "Mathematics of the Discrete Fourier Transform" shows the ring "50 %, Unsicher" in rgb(185, 28, 28) at 24 px

  @wide
  Scenario: From sm upward the badge stays, with a dot in the band's color
    When I open the Eingang
    Then the row "Functional Analysis" shows no ring and a dot in rgb(21, 128, 61)

  @wide
  Scenario: Candidates are chosen by digit, the header follows, nothing is decided
    When I open the Eingang
    And I open the row "Functional Analysis"
    Then no candidate is chosen
    And candidate 1 shows a cover
    And candidate 1 says "Wie der Vorschlag"
    And candidate 2 shows no cover
    And candidate 2 says "Anders als der Vorschlag: Autoren K. Yoshida · Verlag Springer"
    When I press "2"
    Then candidate 2 is chosen
    And the drawer's top shows "K. Yoshida"
    And the drawer shows "80 % · Prüfen" and "Kandidat: Dateiname"
    And the hub wasn't asked anything
    When I press "2"
    Then no candidate is chosen
    And the drawer shows "98 % · Sicher" and "ISBN im Buch, Katalog passt"
    When I press "9"
    Then no candidate is chosen
    When I press "2"
    And I press "a"
    Then the hub was asked to accept candidate 2 of the row

  @wide
  Scenario: A choice stays with the entry: in the row, in editing, in a bulk
    When I open the Eingang
    And I open the row "Functional Analysis"
    And I press "2"
    And I press "e"
    Then the title field reads "Functional Analysis" and the authors "K. Yoshida"
    When I press "Escape"
    Then the row of "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf" shows "80 % · Prüfen", then "Functional Analysis" and "K. Yoshida"
    When I press the part "Neu, sicher: 2"
    And I press the button "Alle 2 übernehmen"
    Then the bulk carries the chosen candidate 2

  Scenario: Candidates are chosen by touch too
    When I open the Eingang
    And I open the row "Functional Analysis"
    And I choose candidate 2 by touch
    Then candidate 2 is chosen
    And the hub wasn't asked anything

  @wide
  Scenario: Reading in with o, turning with h and l, Esc back to the entry
    Given I watch what is saved about reading
    When I open the Eingang
    And I open the row "Functional Analysis"
    Then the drawer has a button "Reinlesen o"
    When I press "o"
    Then the file opens in the reader over the drawer
    And the hub was asked for the file "1/PDF/first"
    And the reader says "Erste 30 Seiten"
    When I press "a"
    And I press "d"
    And I press "j"
    Then the hub wasn't asked anything
    When I press "l"
    Then the reader has turned a page
    When I press "h"
    Then the reader is back on the first page
    When I press "Escape"
    Then no reader is open
    And the drawer's header reads "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf"
    And nothing was saved about reading

  Scenario: Tapping the cover reads in too
    When I open the Eingang
    And I open the row "Functional Analysis"
    And I tap the cover in the drawer
    Then the file opens in the reader over the drawer

  Scenario: On E-Ink reading in turns pages by tap, as the reader does
    Given I open the library
    And E-Ink mode is on
    When I open the Eingang
    And I open the row "Functional Analysis"
    And I tap the cover in the drawer
    Then the file opens in the reader over the drawer
    When I tap the right third of the page
    Then the reader has turned a page

  @wide
  Scenario: A DjVu is read in as a PDF of its first pages
    When I open the Eingang
    And I open the row "Mathematics of the Discrete Fourier Transform"
    Then the drawer has a button "Reinlesen o"
    When I press "o"
    Then the file opens in the reader over the drawer
    And the hub was asked for the file "5/DJVU/first"
    And the reader says "Erste 30 Seiten"

  @wide
  Scenario: What came whole isn't called an excerpt
    When I open the Eingang
    And I open the row "Birds"
    And I press "o"
    Then the file opens in the reader over the drawer
    And the reader doesn't say "Erste 30 Seiten"

  @wide
  Scenario: CHM can't be read in, one muted line says so
    When I open the Eingang
    And I open the row "Basic Pathology"
    Then the drawer offers no reading in
    And the drawer shows "Reinlesen geht bei CHM nicht"
    When I press "o"
    Then no reader is open
    And the drawer's header reads "Robbins - Basic Pathology 8e.chm"

  Scenario: The sure duplicates are what the list shows, they go to the trash after asking
    When I open the Eingang
    Then there is no button "Alle 1 in den Papierkorb"
    When I choose "Mögliche Dubletten (1)" in "Art"
    Then there is no button "Alle 1 in den Papierkorb"
    When I choose "Sichere Dubletten (1)" in "Art"
    Then the bulk's button "Alle 1 in den Papierkorb" is outlined in red
    And the list has 1 rows
    When I press the button "Alle 1 in den Papierkorb"
    Then a dialog asks "1 sichere Dublette geht in den Papierkorb. Die Bibliothek hat Buch oder Datei schon, oder eine Kopie bleibt im Eingang."
    When I press the dialog's "Abbrechen"
    Then the hub wasn't asked anything
    And the list has 1 rows
    When I press the button "Alle 1 in den Papierkorb"
    And I press the dialog's "In den Papierkorb"
    Then the hub was asked to "trash" 1 entry
    And the hub was told to expect 1
    And a message says "1 Datei geht in den Papierkorb."
    And the list says "Hier ist nichts zu entscheiden."
    And there is no button "Alle 0 in den Papierkorb"
    And the filter "Art" offers "Sichere Dubletten (0)"
    When I choose "Mögliche Dubletten (1)" in "Art"
    Then the list has 1 rows
    And the row "Stem Cells: From Bench to Bedside" says "Dublette von „Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf“ im Eingang"

  Scenario: Band and source narrow the sure duplicates, the list and the button stay the same number
    Given every possible duplicate is the same as its book
    And files came in by the inbox and an upload
    When I open the Eingang
    And I choose "Sichere Dubletten (2)" in "Art"
    Then the list has 2 rows
    When I choose "Sicher ab 90 (0)" in "Sicherheit"
    Then the list says "Hier ist nichts zu entscheiden."
    And there is no button "Alle 0 in den Papierkorb"
    When I choose "Prüfen (2)" in "Sicherheit"
    And I choose "Upload (1)" in "Quelle"
    Then the list says "Hier ist nichts zu entscheiden."
    And there is no button "Alle 0 in den Papierkorb"
    When I choose "Inbox (158)" in "Quelle"
    Then the list has 2 rows
    When I press the button "Alle 2 in den Papierkorb"
    Then a dialog asks "2 sichere Dubletten gehen in den Papierkorb. Die Bibliothek hat Buch oder Datei schon, oder eine Kopie bleibt im Eingang."
    When I press the dialog's "In den Papierkorb"
    Then the hub was asked to "trash" 2 entries
    And the hub was told to expect 2
    And a message says "2 Dateien gehen in den Papierkorb."
    And the list says "Hier ist nichts zu entscheiden."

  Scenario: What calibre refused without a book stays for a person and says so in German
    Given calibre refused a possible duplicate as one of two books
    When I open the Eingang
    And I choose "Mögliche Dubletten (1)" in "Art"
    Then the row "Stem Cells: From Bench to Bedside" says "Dublette?"
    And the row "Stem Cells: From Bench to Bedside" says "Das hat nicht geklappt: calibre lehnt das als Dublette ab, es gibt schon „Stem Cells (Ariff Bongso)“, „Stem Cells 2 (Eng Hin Lee)“."

  Scenario: A book renamed since the list was shown trashes nothing, the number follows
    Given the book of a possible duplicate was renamed
    When I open the Eingang
    And I choose "Sichere Dubletten (1)" in "Art"
    And I press the button "Alle 1 in den Papierkorb"
    And I press the dialog's "In den Papierkorb"
    Then a message says "Die Liste hat sich geändert, bitte noch einmal."
    And the hub wasn't asked anything
    And the list says "Hier ist nichts zu entscheiden."
    And there is no button "Alle 0 in den Papierkorb"

  Scenario: The library's books have their proposals in the same list
    When I open the Eingang
    Then the page has no button "Bestand neu prüfen"
    When I choose "Schon in der Bibliothek (3)" in "Art"
    Then the list has 3 rows
    And the row "Formulas and Theorems in Pure Mathematics" has no trash
    And the first line of the row "Formulas and Theorems in Pure Mathematics" is "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu"
    And the button "Bestand neu prüfen" is enabled
    When I press the button "Bestand neu prüfen"
    Then the button "Bestand neu prüfen" is enabled

  @wide
  Scenario: A library entry's drawer: old to new, three exits, no file exits by key
    When I open the Eingang
    And I choose "Schon in der Bibliothek (3)" in "Art"
    And I open the row "Formulas and Theorems in Pure Mathematics"
    Then the drawer has the buttons "Übernehmen a", "Überspringen j" and "Ablehnen x"
    And the drawer changes "Verlag" from "–" to "Chelsea"
    When I press "d"
    And I press "f"
    Then the hub wasn't asked anything
    When I press "x"
    Then the hub was asked to "reject" 1 entry
    When I press "Escape"
    Then the list has 2 rows

  Scenario: A proposal that writes nothing is not in the list, and an empty list keeps the recheck
    When I open the Eingang
    And I choose "Schon in der Bibliothek (3)" in "Art"
    Then the list has 3 rows
    And the row "Nur ein Kandidat.pdf" is gone
    And the page has no bulk
    When I press "Ablehnen" on the row "Formulas and Theorems in Pure Mathematics"
    And I press "Ablehnen" on the row "Dune"
    And I press "Ablehnen" on the row "Wine Tasting - A Professional Handbook.pdf"
    Then the list says "Hier ist nichts zu entscheiden."
    And the button "Bestand neu prüfen" is enabled
    And the legend has no row "Schon in der Bibliothek"
    And the filter "Art" offers "Schon in der Bibliothek (0)"

  Scenario: The old address of the import page leads here
    When I open "/import"
    Then the page is the Eingang
    And the menu has no link "Altbestand"

  Scenario: The Metadaten page has nothing of the old import
    When I open "/metadata"
    Then the page has no "Altbestand"
    And the page has no "Portion"

  @wide
  Scenario: A library book's decision takes it from the list
    When I open the Eingang
    And I choose "Schon in der Bibliothek (3)" in "Art"
    And I press "Übernehmen" on the row "Dune"
    Then the row "Dune" is gone
    And the hub was asked to "accept" 1 entry

  Scenario: An accept that finds a field changed comes back and says why
    When I open the Eingang
    And I choose "Schon in der Bibliothek (3)" in "Art"
    And I press "Übernehmen" on the row "Wine Tasting - A Professional Handbook.pdf"
    Then the row "Wine Tasting - A Professional Handbook.pdf" says "Das hat nicht geklappt: Titel wurde seit dem Vorschlag geändert. Bitte ablehnen oder Bestand neu prüfen."
    And the row "Wine Tasting - A Professional Handbook.pdf" can't be accepted

  Scenario: A reader has no Eingang
    Given I am logged in as "lea"
    Then there is no link "Eingang"

  # The hub takes a file in only when it may move it out of its folder
  # afterwards; on 2026-11-07 107 folders lacked group srv and 2,829 files
  # lay there, only the log knew (#8622). The scenario "rechte" has those.
  Scenario: Folders the hub may not write show above the list, the fullest first
    When I open the demo scenario "rechte"
    Then a note above the list says "2.829 Dateien nicht beschreibbar für den Hub"
    And the note says "Gruppe srv und Schreibrecht fehlen"
    And the note's folders are hidden
    When I open the note's folders "Ordner zeigen (107)"
    Then the note's first folder is "Networks" with "306 Dateien"
    And the note lists 10 folders and "und 97 weitere"
    And the page is no wider than the screen

  Scenario: With every folder writable there is no note
    When I open the Eingang
    Then there is no note about folders the hub may not write
