# Reading lists, like playlists.
#
# The mock library starts with three lists: "Leseliste" (default list,
# favorite, synced; the books that had the tag), "Urlaub" (favorite, used
# last) and "Klassiker". The bookmark on a cover saves to the default list;
# a long press (touch) or a right click opens "In Listen speichern" with a
# checkbox per list. The palette lists the lists with the prefix "l ".

Feature: Reading lists

  Background:
    Given I am logged in

  Scenario: The bookmark on the cover saves to the default list
    Given a book on the first page that is not in "Leseliste"
    When I tap the bookmark on its cover
    Then the bookmark on its cover is set
    And the book is in the list "Leseliste"
    When I tap the bookmark on its cover
    Then the book is not in the list "Leseliste"

  @wide
  Scenario: Wide: a right click on the bookmark opens the save dialog
    Given a book on the first page that is not in "Leseliste"
    When I right-click the bookmark on its cover
    Then the dialog "In Listen speichern" opens with a checkbox per list
    When I check "Klassiker" in the dialog
    Then the book is in the list "Klassiker"

  @narrow
  Scenario: Narrow: a long press on the bookmark opens the save dialog
    Given a book on the first page that is not in "Leseliste"
    When I long-press the bookmark on its cover
    Then the dialog "In Listen speichern" opens with a checkbox per list
    When I check "Klassiker" in the dialog
    Then the book is in the list "Klassiker"

  Scenario: Saving into a new list from the detail
    Given the detail of a book is open
    When I click "Speichern" in the detail
    And I create the list "Krimis" in the dialog
    Then "Krimis" is checked in the dialog
    And the book is in the list "Krimis"

  Scenario: The detail offers the list used last
    Given the detail of a book is open
    Then the detail has the button "In Urlaub"
    When I click "In Urlaub" in the detail
    Then the book is in the list "Urlaub"

  @wide
  Scenario: Wide: the sidebar shows the lists, favorites first
    Then the sidebar section "Listen" shows "Leseliste", "Urlaub", "Klassiker" in this order

  Scenario: A list page with description, covers and count
    When I open the list "Urlaub"
    Then I see the heading "Urlaub"
    And I see the text "Für den Sommer am Meer."
    And I see the text "3 Bücher"
    And the sort is "Zuletzt hinzugefügt"
    And the library shows 3 books

  Scenario: The palette lists the lists with "l "
    Given the command palette is open
    When I type "l urlau" in the palette
    Then the palette suggests the list "Urlaub"
    When I press Enter
    Then the palette closes
    And I see the heading "Urlaub"

  Scenario: Creating a list from the palette
    Given the command palette is open
    When I type "> Neue Liste: Sommer 2027" in the palette
    Then "Neue Liste: Sommer 2027" is the first and selected entry
    When I press Enter
    Then I see the heading "Sommer 2027"
    And the list "Sommer 2027" exists

  Scenario: Adding the open book to a list from the palette
    Given the detail of a book is open
    When I press "Control+k"
    Then the command palette opens
    When I type "> zu liste klass" in the palette
    Then "Zu Liste: Klassiker" is the selected entry
    When I press Enter
    Then the book is in the list "Klassiker"

  Scenario: Bulk: adding the selection to a list and removing it again
    Given I select the first 2 books
    When I add the selection to the list "Klassiker"
    Then the bulk bar says "2 zu Klassiker hinzugefügt"
    When I open the list "Klassiker"
    Then the library shows 2 books
    When I select the first 1 books
    And I remove the selection from this list
    Then the bulk bar says "1 aus Klassiker entfernt"
    And the library shows 1 books
