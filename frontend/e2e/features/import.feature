# Backlog import: its progress live in the hub, not only in the CLI.
#
# The mock hub imports a portion of 500 books of the backlog (5 more each
# time the page polls), while a dry run walks another folder. The whole
# backlog has about 18,590 new books; the metadata and embed hooks wait
# for the import with 1,360 books.

Feature: Import progress

  Background:
    Given I am logged in

  Scenario: The import page shows the phase, the whole backlog and the running import
    When I open the import page
    Then the import phase is "Import"
    And the backlog bar shows the imported share of about 18.590 new books
    And the backlog lists "Offen:" with "292 Duplikate, 2 fehlgeschlagen"
    And the running import is at "/srv/media/ebooks/backlog/Fontane, Theodor/Effi Briest (412)"
    And the running import shows "Laufzeit 1 Std. 02 Min. · 21,5 Bücher/min · noch etwa 4 Min. 10 s"
    And the running import lists the failed book "/srv/media/ebooks/backlog/Unbekannt/kaputt.pdf" with "calibre-server: HTTP 500 (NoSuchBook)"
    And the scan of the dry run shows "135,2 Dateien/s" at "/srv/media/ebooks/neu/Comics/Asterix"

  Scenario: The progress updates by itself
    When I open the import page
    Then the running import's count goes up without reloading the page

  Scenario: The followup shows the hooks' queues of the imported books
    When I open the import page
    Then the followup shows "Metadaten 1.300, Einbetten 60"
    And the followup waits for the import

  Scenario: The runs are listed with their results and reports
    When I open the import page
    Then the runs list a finished import that took "Dauer 1 Std. 02 Min. · 20,2 Bücher/min"
    And the runs link 3 reports

  Scenario: The quality report measures the library and the last runs
    When I open the import page
    Then the quality report says "212 von 1.846 Büchern auffällig"
    And the quality report counts "Autor unbekannt" with "191"
    And the quality report lists a run with "120 von 437 auffällig"

  Scenario: The quality report shows the bands and keeps a sample check
    When I open the import page
    Then the quality report counts "sicher (ab 90)" with "900"
    And the quality report counts "im Buch, per OCR" with "120 (15 %)"
    And the quality report shows "Konflikte: 1 ISBN doppelt, 3 Bücher vermerkt"
    When I draw a sample and record 29 of 30 right
    Then the quality report shows "sicher (ab 90): 29 von 30 richtig (97 %)"

  Scenario: The repair shows how sure a proposal is, filters and accepts a band
    When I open the import page
    Then the first proposal says "Sicherheit 98, ISBN im Buch"
    When I show the band "unsicher (unter 60)" of the repair
    Then the repair lists 1 proposals
    When I show the band "alle" of the repair
    And I sort the repair by "unsicherste zuerst"
    Then the first proposal says "Sicherheit 30, Dateiname"
    When I show the level "ISBN im Buch" of the repair
    Then the repair lists 1 proposals
    When I show the level "alle" of the repair
    And I accept the sure proposals
    Then the repair has 2 open proposals and "1 übernommen"

  Scenario: The repair of plain-file imports is reviewed book by book
    When I open the import page
    Then the repair proposes "Formulas and Theorems in Pure Mathematics" decided by "Dateiname"
    And the repair proposes "Dune" decided by "Hardcover"
    And the repair lists a book decided by "unsicher, Tag auto-unsicher zur Prüfung"
    When I accept the repair of the first proposal
    Then the repair has 2 open proposals and "1 übernommen"
    When I select the first proposal and reject the selected ones
    Then the repair has 1 open proposals and "1 abgelehnt"

  Scenario: A proposal opens next to its book and is decided there
    When I open the import page
    Then the first proposal shows a cover and links to its book
    When I click the first proposal
    Then the drawer shows the proposal "→ Dune" and the book
    When I accept the proposal in the drawer
    Then the drawer shows the proposal "→ Formulas and Theorems in Pure Mathematics" and the book
    When I close the drawer
    Then the repair has 2 open proposals and "1 übernommen"

  Scenario: Proposals are decided by key in the drawer
    When I open the import page
    And I click the first proposal
    Then the drawer shows the proposal "→ Dune" and the book
    When I press "j"
    Then the drawer shows the proposal "→ Formulas and Theorems in Pure Mathematics" and the book
    When I press "k"
    Then the drawer shows the proposal "→ Dune" and the book
    When I press "a"
    Then the drawer shows the proposal "→ Formulas and Theorems in Pure Mathematics" and the book
    When I press "x"
    And I close the drawer
    Then the repair has 1 open proposals and "1 übernommen"
    And the repair has 1 open proposals and "1 abgelehnt"

  Scenario: The next portion is checked by a dry run, then started
    Given the import is "idle"
    When I open the import page
    Then the next portion offers no start
    When I check the next portion
    Then the next portion says "Ein Probelauf läuft gerade."
    And the next portion shows "17.900 Bücher, 6.000 aus calibre-Ordnern; neu 17.500, Formate ergänzen 100, Duplikate 300, schon importiert 1.500, übersprungen 2.100"
    And the next portion shows "dieser Lauf: 508 Bücher (höchstens 500 neue), 17.392 für spätere Läufe"
    And the next portion shows "davon neu 490, Formate ergänzen 10, Duplikate 8"
    And the review fits the screen
    When I start the portion of 508 books
    Then the next portion says "Ein Import läuft gerade."
    And the next portion offers no start
    And the hub got a dry run of 500 books, then an import of 500 books

  Scenario: Another limit needs its own dry run
    Given the import is "idle"
    When I open the import page
    And I check the next portion
    Then the next portion can start 508 books
    When I set the portion to 200 books
    Then the next portion says "Die Anzahl ist geändert, bitte neu prüfen."
    And the next portion offers no start
    When I check the next portion
    Then the next portion can start 208 books
    When I start the portion of 208 books
    Then the hub got a dry run of 500 books, a dry run of 200 books, then an import of 200 books

  Scenario: A limit below 1 is refused
    Given the import is "idle"
    When I open the import page
    And I set the portion to 0 books
    Then the next portion is blocked by "Bitte eine ganze Zahl ab 1 eintragen."

  Scenario: A dry run from before is still there
    Given the import is "reviewed"
    When I open the import page
    Then the next portion can start 508 books

  Scenario: No portion while an import runs
    When I open the import page
    Then the next portion is blocked by "Ein Import läuft gerade."

  Scenario: No portion while the followup has work
    Given the import is "followup"
    When I open the import page
    Then the next portion is blocked by "Der Nachlauf hat noch 120 Bücher offen."

  Scenario: No portion while a repair plan runs
    Given the import is "planning"
    When I open the import page
    Then the next portion is blocked by "Die Reparatur plant gerade."

  Scenario: Open proposals leave the next portion free
    Given the import is "idle"
    When I open the import page
    Then the repair has 3 open proposals and "0 übernommen"
    And the next portion can be checked

  Scenario: Nothing left in the backlog
    Given the import is "empty"
    When I open the import page
    Then the next portion shows "Im Altbestand ist nichts mehr offen."
    When I check the next portion
    Then the next portion shows "0 Bücher, 0 aus calibre-Ordnern; neu 0, Formate ergänzen 0, Duplikate 0, schon importiert 1.500, übersprungen 2.100"
    And the next portion offers no start

  @narrow
  Scenario: On a phone the page fits the screen
    When I open the import page from the menu
    Then the page doesn't scroll sideways
