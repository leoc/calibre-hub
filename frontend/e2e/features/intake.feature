# The Eingang: what the analysis found in the backlog, before anything is in
# the library, and the four ways out of the list.
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
    Then the drawer's header reads "Stewart Calculus Concepts and Contexts 2nd Edition.pdf"
    And the row "Calculus: Concepts and Contexts" is marked as the current one
    When I press "k"
    Then the drawer's header reads "Birds.pdf"
    And each candidate has its digit
    When I press "j" 19 times
    Then the drawer's header reads "scan-013.pdf"
    And the row "scan-013" is in view
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
    And I open the row "1380293052863"
    Then the drawer has the buttons "Übernehmen a", "Wie in der Datei f", "Überspringen j" and "Papierkorb d"
    And the button "Papierkorb d" is outlined in red
    And the drawer shows "k zurück · e bearbeiten · Esc schließen"
    When I press "a"
    Then the hub was asked to "accept" 1 entry
    And the drawer's header reads "Birds.pdf"
    When I press "f"
    Then the hub was asked to "file" 1 entry
    And the drawer's header reads "Stewart Calculus Concepts and Contexts 2nd Edition.pdf"
    When I press "d"
    Then the hub was asked to "trash" 1 entry
    And the drawer's header reads "Functional Analysis 6th ed - K. Yoshida (Springer, 1980) WW.pdf"
    And no dialog asks anything

  @wide
  Scenario: Keys leave modifiers and held keys alone
    When I open the Eingang
    And I open the row "1380293052863"
    And I press "Control+a"
    And I hold "a" down
    Then the hub was asked to "accept" 1 entry
    And the drawer's header reads "Birds.pdf"

  @wide
  Scenario: Skipping marks the entry and moves on, back changes nothing
    When I open the Eingang
    And I open the row "Britannica Illustrated Science Library: Birds"
    And I press "j"
    Then the hub was asked to "skip" 1 entry
    And the drawer's header reads "Stewart Calculus Concepts and Contexts 2nd Edition.pdf"
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
    And the drawer's header reads "kaputt.pdf"

  Scenario: A decision that failed comes back with its reason
    When I open the Eingang
    And I choose "Fehlgeschlagen (1)" in "Sicherheit"
    And I press "Papierkorb" on the row "kaputt.pdf"
    Then the row "kaputt.pdf" says "Das hat nicht geklappt: calibre kann die Datei nicht lesen"

  Scenario: The threshold hides behind one button
    When I open the Eingang
    Then the button "Automatisch übernehmen: aus" is enabled
    When I press the button "Automatisch übernehmen: aus"
    And I set "Ab Sicherheit (60 bis 100)" to "59"
    Then the dialog's "Einschalten" is disabled
    When I set "Ab Sicherheit (60 bis 100)" to "95"
    And I press the dialog's "Einschalten"
    Then the button "Automatisch übernehmen: ab 95 %" is enabled
    When I press the button "Automatisch übernehmen: ab 95 %"
    And I press the dialog's "Ausschalten"
    Then the button "Automatisch übernehmen: aus" is enabled

  Scenario Outline: One muted line when the analysis stands still
    Given the analysis is "<state>"
    When I open the Eingang
    Then the page says "<hint>"

    Examples:
      | state  | hint                                                      |
      | paused | Die Analyse wartet, bis Import oder Reparatur fertig sind. |
      | off    | Die Analyse ist ausgeschaltet.                            |

  Scenario: Nothing while the analysis runs normally
    When I open the Eingang
    Then the page says nothing about the analysis

  @narrow
  Scenario: On a phone the confidence is a ring
    When I open the Eingang
    Then the row "Functional Analysis" shows the ring "98 %, Sicher" in rgb(21, 128, 61) at 24 px
    And the row "Basic Pathology" shows the ring "70 %, Prüfen" in rgb(180, 83, 9) at 24 px
    And the row "1380293052863" shows the ring "10 %, Unsicher" in rgb(185, 28, 28) at 24 px

  @wide
  Scenario: From sm upward the badge stays, with a dot in the band's color
    When I open the Eingang
    Then the row "Functional Analysis" shows no ring and a dot in rgb(21, 128, 61)

  Scenario: A reader has no Eingang
    Given I am logged in as "lea"
    Then there is no link "Eingang"
