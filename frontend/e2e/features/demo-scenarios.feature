# The situations of the mock Eingang for showing a change (dev/mock): chosen by
# the URL or the switcher, which only `pnpm dev:mock` has. They hold for the
# tab, and the default stays the Eingang the other features know.

Feature: Demo scenarios

  Scenario: A full Eingang has all parts, nothing left to analyse
    When I open the demo scenario "voll"
    Then the line under the title says "503 Dateien warten auf dich, alle analysiert"
    And the filter "Art" offers "Neue Dateien (400)"
    And the filter "Art" offers "Mögliche Dubletten (50)"
    And the filter "Art" offers "Sichere Dubletten (40)"
    And the filter "Art" offers "Übersprungen (10)"

  Scenario: An empty Eingang
    When I open the demo scenario "leer"
    Then the line under the title says "Nichts wartet auf dich, alle analysiert"
    And the list says "Hier ist nichts zu entscheiden."

  Scenario: Many duplicates
    When I open the demo scenario "dubletten"
    Then the filter "Art" offers "Sichere Dubletten (120)"
    And the filter "Art" offers "Mögliche Dubletten (100)"

  Scenario: The switcher changes the scenario and it stays for the tab
    When I open the demo scenario "leer"
    And I switch the demo to "Eingang voll"
    Then the line under the title says "503 Dateien warten auf dich, alle analysiert"
    When I load the Eingang again
    Then the line under the title says "503 Dateien warten auf dich, alle analysiert"

  Scenario: A decision stays while the page does
    When I open the demo scenario "dubletten"
    And I trash the first sure duplicate
    Then the filter "Art" offers "Sichere Dubletten (119)"

  Scenario: The default is the running analysis
    When I open the demo scenario "analyse"
    Then the line under the title says "1.292 von 1.454 noch zu analysieren"
    And the demo switcher says "Demo: Analyse läuft"
