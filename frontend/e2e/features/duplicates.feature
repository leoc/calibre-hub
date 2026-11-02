# Duplicates: books that look like the same book, merged into one.
#
# The mock library has two seeded pairs like the live library: "Stop
# Letting Everything Affect You" twice (two editions, the subtitle only
# differs in case; the second copy also has a PDF and a publisher) and
# "Implementing ISO 9001:2015" next to an Anna's Archive leftover of 80
# bytes with the same ISBN in its file-name title. Merging keeps one book,
# moves the formats and fields it lacks and puts the others into the
# trash; "Rückgängig" brings them back.

Feature: Duplicates

  Background:
    Given I am logged in

  Scenario: The groups are compared side by side with the book to keep
    When I open the duplicates page
    Then I see the group "Implementing ISO 9001:2015" with the reasons "Gleiche ISBN 9781908984500" and "Defekte Datei"
    And the group "Implementing ISO 9001:2015" suggests keeping "Implementing ISO 9001:2015"
    And the leftover in the group "Implementing ISO 9001:2015" is marked "defekt"
    And the group "Stop Letting Everything Affect You" compares 2 books

  Scenario: Merging keeps one book with both formats, the other goes to the trash, undo brings it back
    When I open the duplicates page
    And I start merging the group "Stop Letting Everything Affect You"
    Then the merge dialog says that "PDF" comes along and the other book goes to the trash
    When I click "Zusammenführen" in the dialog
    Then the page says the books were merged
    And the kept book has the formats "EPUB, PDF" and the publisher "Undercover Publishing House"
    And the other book is in the trash
    And the group "Stop Letting Everything Affect You" is no longer shown
    When I undo the merge
    Then the other book is back in the library with a new id
    And the kept book has the formats "EPUB" and no publisher

  Scenario: Marking a group as no duplicates, with undo
    When I open the duplicates page
    And I click "Keine Duplikate" in the group "Implementing ISO 9001:2015"
    Then a toast says "Als keine Duplikate markiert"
    And the group "Implementing ISO 9001:2015" is no longer shown
    When I click "Rückgängig" in the toast
    Then I see the group "Implementing ISO 9001:2015" with the reasons "Gleiche ISBN 9781908984500" and "Defekte Datei"

  Scenario: The palette leads to the duplicates
    When I run the command "Duplikate" in the palette
    Then the duplicates page is shown

  @wide
  Scenario: Wide: the sidebar leads to the duplicates
    When I click "Duplikate" in the sidebar
    Then the duplicates page is shown

  @wide
  Scenario: Wide: gD in Vim mode
    Given keyboard mode is "vim"
    When I type "gD"
    Then the duplicates page is shown
