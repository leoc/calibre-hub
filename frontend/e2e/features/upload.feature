# An upload is a file for the Eingang: the tray stays with it until something
# came of it, so no book vanishes without a word.

Feature: Upload

  Background:
    Given I am logged in
    And I open the library

  Scenario: A sure book reaches the library
    When I upload "Neues Buch.epub"
    Then the tray says "Wird im Eingang geprüft …"
    And the tray offers "Bearbeiten"

  Scenario: Below the threshold it waits in the Eingang, and the tray says so
    When I upload "Unsicheres Buch.epub"
    Then the tray says "Wartet im Eingang: 75 %, von selbst übernommen wird ab 90 %."
    When I follow the tray's link "Zum Eingang"
    Then the page is the Eingang

  Scenario: The same file is in the library
    When I upload "Kopie.epub"
    Then the tray says "Die gleiche Datei ist schon in der Bibliothek:"
    And the tray offers "Trotzdem als neues Buch"

  Scenario: A book that looks like one of the library becomes a format of it
    When I upload "Zweites Buch.epub"
    Then the tray offers "Bearbeiten"
    When I upload "Zweites Buch.pdf"
    Then the tray says "Schon in der Bibliothek:"
    When I press the tray's "PDF hinzufügen"
    Then the tray offers 2 times "Bearbeiten"
