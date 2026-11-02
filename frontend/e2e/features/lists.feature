# Reading lists, like playlists.
#
# The mock library starts with three lists: "Leseliste" (default list,
# favorite, synced; the books that had the tag), "Urlaub" (favorite, used
# last) and "Klassiker". The bookmark on a cover saves to the default list;
# a long press (touch) or a right click opens "In Listen speichern" with a
# checkbox per list. The palette lists the lists with the prefix "l ".
# The sidebar shows the favorites; "Alle Listen" leads to the overview.

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
  Scenario: Wide: the sidebar shows the favorite lists only
    Then the sidebar section "Listen" shows "Leseliste", "Urlaub" in this order
    And the sidebar links to "Alle Listen" with the count 3
    When I click "Alle Listen" in the sidebar
    Then I see the heading "Listen"
    And the overview shows "Leseliste", "Urlaub", "Klassiker"

  Scenario: The overview of all lists
    When I run the command "Listen" in the palette
    Then I see the heading "Listen"
    And the overview shows "Leseliste", "Urlaub", "Klassiker"
    And the overview shows "3 Bücher" and the badge "Favorit" for "Urlaub"
    When I click "Favorit" for "Klassiker" in the overview
    Then the list "Klassiker" is a favorite
    When I click "Synchronisieren" for "Urlaub" in the overview
    Then the list "Urlaub" is synced
    When I click "Standardliste" for "Klassiker" in the overview
    Then the list "Klassiker" is the default list
    And the list "Leseliste" is not the default list

  Scenario: Deleting a list from the overview asks first
    When I run the command "Listen" in the palette
    And I click "Löschen" for "Klassiker" in the overview
    Then the dialog "Liste löschen" asks about "Klassiker"
    When I click "Ja, Liste löschen" in the dialog
    Then the overview shows "Leseliste", "Urlaub"
    And I see the heading "Listen"

  Scenario: Creating a list from the overview
    When I run the command "Listen" in the palette
    And I create the list "Sommer 2027" in the overview
    Then I see the heading "Sommer 2027"
    And the list "Sommer 2027" exists

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
    Then a toast says "1 Buch aus Klassiker entfernt"
    And the library shows 1 books

  Scenario: Bulk: removing from this list asks nothing and can be undone
    When I open the list "Urlaub"
    And I select the first 2 books
    And I remove the selection from this list
    Then a toast says "2 Bücher aus Urlaub entfernt"
    And the library shows 1 books
    When I click "Rückgängig" in the toast
    Then the toast is gone
    And the library shows 3 books
    And the list "Urlaub" has 3 books
