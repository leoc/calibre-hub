# Private tags: tags a user puts on books for themselves. They live in the
# hub per user, never in calibre's tags, which everyone shares; nobody else
# sees them. Readers keep them too: they select books for their own lists
# and private tags, but change nothing of the library. The mocks keep the
# tags per logged-in user ("lea" is a reader, anyone else the admin); the
# mock state lives in the page, so the steps stay inside the app.

Feature: Private tags

  @wide
  Scenario: A reader tags her selection privately and filters by it
    Given I am logged in as "lea"
    And I selected 2 books
    When I add my tag "Urlaub" to the selection
    Then a message in the selection bar says "Meine Tags hinzufügen: 2 geändert"
    And the 2 selected books have my tag "Urlaub"
    And no selected book has the tag "Urlaub"
    And the sidebar lists my tag "Urlaub" with 2 books
    When I click my tag "Urlaub" in the sidebar
    Then the library shows 2 books
    And there is the filter chip "Mein Tag: Urlaub"

  @wide
  Scenario: A reader's selection bar offers only her own things
    Given I am logged in as "lea"
    And I selected 1 books
    Then the selection bar offers "Meine Tags hinzufügen"
    And the selection bar offers "Zu Liste"
    And the selection bar doesn't offer "Tags hinzufügen"
    And the selection bar doesn't offer "Löschen"

  @wide
  Scenario: A private tag from the command palette, found again with "t "
    Given I am logged in as "arthur"
    And I selected 3 books
    When I type ">"
    And I type "mein tag Abends"
    Then "Neu: Meinen Tag ‚Abends‘ hinzufügen (3)" is the first and selected entry
    When I press "Enter"
    Then the palette closes
    And a message says "Meinen Tag ‚Abends‘ hinzufügen (3): 3 geändert"
    And the 3 selected books have my tag "Abends"
    When I type "t abends" in the empty search bar
    Then the palette shows my tag "Abends" under "Meine Tags"
    When I press "Enter"
    Then the library shows 3 books

  Scenario: Editing my tags in the detail
    Given I am logged in as "lea"
    When I open the first book in the library
    And I set my tags in the detail to "Später"
    Then the detail shows my tag "Später"
    And the book has my tag "Später" but not as a tag of the library
