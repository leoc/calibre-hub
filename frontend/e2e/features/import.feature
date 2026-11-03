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

  Scenario: The repair of plain-file imports is reviewed book by book
    When I open the import page
    Then the repair proposes "Formulas and Theorems in Pure Mathematics" decided by "Dateiname"
    And the repair proposes "Dune" decided by "Hardcover"
    And the repair lists a book decided by "unsicher, Tag auto-unsicher zur Prüfung"
    When I accept the repair of the first proposal
    Then the repair has 2 open proposals and "1 übernommen"
    When I select the first proposal and reject the selected ones
    Then the repair has 1 open proposals and "1 abgelehnt"

  @narrow
  Scenario: On a phone the page fits the screen
    When I open the import page from the menu
    Then the page doesn't scroll sideways
