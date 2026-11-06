# The Eingang: what the analysis found in the backlog, before anything is in
# the library. Read only in this phase.
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
    And nothing can be decided yet

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

  Scenario: A reader has no Eingang
    Given I am logged in as "lea"
    Then there is no link "Eingang"
