# Magic shelves: saved searches shown like reading lists.
#
# A shelf is a list with a rule instead of books of its own: conditions on
# tag, category, author, series, language or free text, joined by AND or
# OR. Its books and its count come from the library every time, so they
# follow every change. It opens like a list (sidebar, overview, palette
# "l "), but is never offered to save a book to. Nobody in the mock library
# has the tag "regaltest".

Feature: Magic shelves

  Background:
    Given I am logged in

  Scenario: Saving the library's filters as a shelf
    Given the library is filtered by the series "Erdsee"
    When I click "Als Regal speichern" in the toolbar
    Then the dialog "Neues magisches Regal" has the rule "Serie" "ist" "Erdsee"
    When I name the shelf "Erdsee-Regal" and create it
    Then I see the heading "Erdsee-Regal"
    And I see the text "Serie ist Erdsee"
    And the shelf shows the books of the series "Erdsee"

  Scenario: A shelf with rules joined by OR
    Given the shelf "Erdsee-Regal" for the series "Erdsee"
    When I click "Regal bearbeiten" on the shelf's page
    And I add the rule "Serie" "ist" "Foundation"
    And I choose "Mindestens eine Regel (ODER)"
    And I save the shelf
    Then I see the text "Serie ist Erdsee oder Serie ist Foundation"
    And the shelf shows the books of the series "Erdsee" and "Foundation"

  @wide
  Scenario: Wide: the shelf's count in the sidebar follows the library
    When I create the shelf "Testregal" for the tag "regaltest" in the overview
    Then I see the text "Kein Buch passt gerade zu den Regeln dieses Regals."
    And the sidebar shows the shelf "Testregal" with the count 0
    When I click "Alle Bücher" in the sidebar
    And I select the first 2 books
    And I add the tag "regaltest" to the selection
    Then the sidebar shows the shelf "Testregal" with the count 2
    When I click "Testregal" in the sidebar
    Then the library shows 2 books

  Scenario: The palette opens a shelf, saving never offers it
    Given the shelf "Erdsee-Regal" for the series "Erdsee"
    When I run the command "Listen" in the palette
    Then the overview shows the shelf "Erdsee-Regal" without sync and default list
    When I open the list "Erdsee-Regal"
    Then the shelf shows the books of the series "Erdsee"
    When I open the first book of the page
    And I click "Speichern" in the detail
    Then the dialog "In Listen speichern" doesn't offer "Erdsee-Regal"
