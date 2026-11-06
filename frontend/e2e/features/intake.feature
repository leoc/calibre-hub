# The Eingang: what the analysis found in the backlog, the inbox and uploads,
# before anything is in the library, and the four ways out of the list.
#
# The mock hub has nine files like the live backlog (a sure ISBN hit, a
# possible duplicate, a file that failed, ...) and 150 scans, the analysis
# standing at one file with 1,451 books in the Eingang.

Feature: Eingang

  Background:
    Given I am logged in

  Scenario: The page shows the numbers, the bar while it analyses and the proposals
    When I open the Eingang
    Then the numbers are "1.451 im Eingang" and "158 analysiert"
    And the analysis bar stands at 11 percent
    And the row of "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf" shows "98 % · Sicher", then "Functional Analysis" and "Kosaku Yosida"
    And the row of "Stewart Calculus Concepts and Contexts 2nd Edition.pdf" shows "78 % · Dublette?", then "Calculus: Concepts and Contexts" and "James Stewart"
    And a row has no checkbox

  Scenario: The menu leads to the Eingang with its count
    Given I open the library
    When I open the Eingang from the menu
    Then the menu shows "1.451" next to the Eingang

  Scenario: Filtering by confidence and kind
    When I open the Eingang
    Then the filter "Sicherheit" offers "Sicher ab 90 (2)"
    When I choose "Sicher ab 90 (2)" in "Sicherheit"
    Then the list has 2 rows
    When I choose "Alle (159)" in "Sicherheit"
    And I choose "Mögliche Dubletten" in "Art"
    Then the list has 2 rows
    And the filter "Sicherheit" offers "Prüfen 60 bis 89 (2)"
    And the numbers are "1.451 im Eingang" and "158 analysiert"

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
    And the numbers are "1.449 im Eingang" and "156 analysiert"

  Scenario: Accepting everything sure asks nothing
    When I open the Eingang
    And I choose "Sicher ab 90 (2)" in "Sicherheit"
    And I press the button "Alle 2 übernehmen"
    Then no dialog asks anything
    And the hub was asked to "accept" 2 entries
    And the list says "Hier ist nichts zu entscheiden."
    And the button "Alle 0 übernehmen" is disabled

  Scenario: Accepting with unsure books in it asks first, across all pages
    When I open the Eingang
    Then the list has 100 rows
    When I press the button "Alle 156 übernehmen"
    Then a dialog asks "156 Bücher, davon 152 unsicher. Trotzdem übernehmen?"
    When I press the dialog's "Abbrechen"
    Then the list has 100 rows
    When I press the button "Alle 156 übernehmen"
    And I press the dialog's "Übernehmen"
    Then the hub was asked to "accept" 156 entries
    And the list has 3 rows
    And the button "Alle 0 übernehmen" is disabled

  Scenario: A row that may be a duplicate says of what and stays out of a bulk
    When I open the Eingang
    And I choose "Mögliche Dubletten" in "Art"
    Then the row "Calculus: Concepts and Contexts" links "Calculus: Concepts and Contexts" to book 1 after "Dublette von"
    And the row "Stem Cells: From Bench to Bedside" says "Dublette von „Stem Cells - From Bench to Bedside - A. Bongso, E. Lee (World, 2005) WW.pdf“ im Eingang"
    And the button "Alle 0 übernehmen" is disabled

  Scenario: A failed file has no proposal to accept
    When I open the Eingang
    And I choose "Fehlgeschlagen (1)" in "Sicherheit"
    Then the row "kaputt.pdf" can't be accepted
    And the button "Alle 0 übernehmen" is disabled

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
    Then the button "Alle 155 übernehmen" is enabled
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

  Scenario: The thresholds hide behind one button, a line per source
    When I open the Eingang
    Then the button "Automatisch übernehmen: Backlog aus, Inbox ab 90 %, Upload ab 90 %" is enabled
    When I press the button "Automatisch übernehmen: Backlog aus, Inbox ab 90 %, Upload ab 90 %"
    And I switch on "Backlog"
    And I set "Backlog: ab Sicherheit (60 bis 100)" to "59"
    Then the dialog's "Speichern" is disabled
    When I set "Backlog: ab Sicherheit (60 bis 100)" to "95"
    And I switch off "Inbox"
    And I press the dialog's "Speichern"
    Then the button "Automatisch übernehmen: Backlog ab 95 %, Inbox aus, Upload ab 90 %" is enabled
    When I press the button "Automatisch übernehmen: Backlog ab 95 %, Inbox aus, Upload ab 90 %"
    And I switch off "Backlog"
    And I switch on "Inbox"
    And I press the dialog's "Speichern"
    Then the button "Automatisch übernehmen: Backlog aus, Inbox ab 90 %, Upload ab 90 %" is enabled

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
    Then the filter "Quelle" offers "Inbox (1)"
    And the filter "Quelle" offers "Upload (1)"
    And the row of "Birds.pdf" shows the source "Inbox"
    When I choose "Inbox (1)" in "Quelle"
    Then the list has 1 rows
    And the button "Alle 1 übernehmen" is enabled
    When I press the button "Alle 1 übernehmen"
    Then the hub was asked to accept the filter of the source "inbox"

  Scenario Outline: One muted line when the analysis stands still
    Given the analysis is "<state>"
    When I open the Eingang
    Then the page says "<hint>"

    Examples:
      | state  | hint                                                      |
      | paused | Die Analyse des Backlogs wartet, bis die Reparatur fertig ist. |
      | off    | Die Analyse des Backlogs ist ausgeschaltet.                            |

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
    When I choose "Sicher ab 90 (2)" in "Sicherheit"
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

  Scenario: The bulk says what it leaves in the list
    When I open the Eingang
    And I choose "Sicher ab 90 (2)" in "Sicherheit"
    Then the page has no line about what stays
    When I choose "Alle (159)" in "Sicherheit"
    Then the page says "2 mögliche Dubletten und 1 fehlgeschlagen bleiben in der Liste"
    When I choose "Mögliche Dubletten" in "Art"
    Then the page says "2 mögliche Dubletten bleiben in der Liste"

  Scenario: The library's books have their proposals in the same list
    When I open the Eingang
    Then the page has no button "Bestand neu prüfen"
    When I choose "Schon in der Bibliothek" in "Art"
    Then the list has 3 rows
    And the row "Formulas and Theorems in Pure Mathematics" has no trash
    And the first line of the row "Formulas and Theorems in Pure Mathematics" is "Carr - Formulas and Theorems in Pure Mathematics 2e (Chelsea, 1970).djvu"
    And the button "Bestand neu prüfen" is enabled
    When I press the button "Bestand neu prüfen"
    Then the button "Bestand neu prüfen" is enabled

  @wide
  Scenario: A library entry's drawer: old to new, three exits, no file exits by key
    When I open the Eingang
    And I choose "Schon in der Bibliothek" in "Art"
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

  @wide
  Scenario: A decision here is gone from the Prüfliste, a failed one says why
    When I open the Eingang
    And I choose "Schon in der Bibliothek" in "Art"
    And I press "Übernehmen" on the row "Dune"
    Then the row "Dune" is gone
    And the hub was asked to "accept" 1 entry
    When I go to the import page
    Then the review has no proposal for "Herbert - Dune.mobi"

  Scenario: An accept that finds a field changed comes back and says why
    When I open the Eingang
    And I choose "Schon in der Bibliothek" in "Art"
    And I press "Übernehmen" on the row "Wine Tasting - A Professional Handbook.pdf"
    Then the row "Wine Tasting - A Professional Handbook.pdf" says "Das hat nicht geklappt: Titel wurde seit dem Vorschlag geändert. Bitte ablehnen oder Bestand neu prüfen."
    And the row "Wine Tasting - A Professional Handbook.pdf" can't be accepted
    And the page says "1 fehlgeschlagen bleibt in der Liste"

  Scenario: A reader has no Eingang
    Given I am logged in as "lea"
    Then there is no link "Eingang"
