# Roles: an admin edits the library, a reader only reads and keeps their own
# lists. The server answers a reader's other writes with 403; the app
# doesn't offer them. The mocks log "lea" in as a reader, anyone else as
# the admin (password "hub"); the mock session lives in the page, so the
# steps navigate inside the app after logging in.

Feature: Roles

  Scenario: A reader sees no editing, upload or selection
    Given I am logged in as "lea"
    Then there is no upload
    And there is no button "Auswählen"
    When I open the first book in the library
    Then the detail offers no button "Bearbeiten"
    And the detail offers no button "Löschen"

  @wide
  Scenario: A reader's sidebar has no library upkeep
    Given I am logged in as "lea"
    Then the sidebar has no link "Papierkorb"
    And the sidebar has no link "Duplikate"

  Scenario: An admin edits, uploads and selects
    Given I am logged in as "arthur"
    Then there is an upload
    And there is a button "Auswählen"
    When I open the first book in the library
    Then the detail offers the button "Bearbeiten"
    And the detail offers the button "Löschen"
