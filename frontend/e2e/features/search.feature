# Search bar and command palette.
#
# Device classes:
#   narrow = viewport width < 640 px (phones)
#   wide   = viewport width >= 640 px (desktop, tablets, E-Ink readers like Boox)
# Scenarios tagged @narrow/@wide run only in that Playwright project.
# Prefixes (only at the start of the input): "a " author, "s " series,
# "t " tag, "k " category, "b " books, ">" commands.

Feature: Search bar and command palette

  Background:
    Given I am logged in
    And the library contains books by "Terry Pratchett" in the series "Scheibenwelt"

  # --- narrow (phones) ------------------------------------------------------

  @narrow
  Scenario: Narrow: tapping the search bar opens the palette
    Given I use a narrow device
    When I tap the search bar
    Then the command palette opens full screen at the top
    And the focus is in the palette input
    And the result list uses the full height below the input

  @narrow
  Scenario: Narrow: the palette starts from the current search
    Given I use a narrow device
    And the library is filtered by "insel"
    When I tap the search bar
    Then the palette input contains "insel"

  @narrow
  Scenario: Narrow: free text becomes the library search
    Given I use a narrow device
    And the command palette is open
    When I type "pratchett" in the palette
    And I press Enter
    Then the palette closes
    And the library shows the results for "pratchett"
    And the search bar shows "pratchett"

  @narrow
  Scenario: Narrow: choosing a scope with a chip instead of a prefix
    Given I use a narrow device
    And the command palette is open
    When I tap the chip "Serien"
    Then the palette input contains "s "
    And only series are suggested

  @narrow
  Scenario: Narrow: closing the palette changes nothing
    Given I use a narrow device
    And the library is filtered by "insel"
    And the command palette is open
    When I type "pratchett" in the palette
    And I close the palette
    Then the library is still filtered by "insel"

  # --- wide (desktop, tablets, E-Ink readers) -------------------------------

  @wide
  Scenario: Wide: free text filters the library directly
    Given I use a wide device
    When I type "pratchett" in the search bar
    Then the palette stays closed
    And the library shows the results for "pratchett"
    And the URL contains "q=pratchett"

  @wide
  Scenario Outline: Wide: a prefix in the search bar opens the palette
    Given I use a wide device
    When I type the prefix "<prefix>" in the empty search bar
    Then the command palette opens
    And the palette input contains the prefix "<prefix>"
    And the focus is in the palette input
    And the library search is unchanged

    # letters are followed by a space ("a "), ">" stands alone
    Examples:
      | prefix |
      | a      |
      | s      |
      | t      |
      | k      |
      | b      |
      | >      |

  @wide
  Scenario: Wide: typing on after the prefix goes into the palette
    Given I use a wide device
    When I type "a pra" in the empty search bar
    Then the palette input contains "a pra"
    And only authors are suggested, including "Terry Pratchett"

  @wide
  Scenario: Wide: a prefix is only recognised at the start
    Given I use a wide device
    When I type "drama s" in the search bar
    Then the palette stays closed
    And the library shows the results for "drama s"

  @wide
  Scenario: Wide: pasting text with a prefix opens the palette
    Given I use a wide device
    When I paste "a terry pratchett" into the empty search bar
    Then the command palette opens
    And the palette input contains "a terry pratchett"

  @wide
  Scenario: Wide: the command button takes the search bar text along
    Given I use a wide device
    And the library is filtered by "insel"
    When I click the command button in the search bar
    Then the command palette opens
    And the palette input contains "insel"

  @wide
  Scenario Outline: Wide: keyboard shortcuts open the palette
    Given I use a wide device
    And the focus is not in an input
    When I press "<key>"
    Then the command palette opens

    Examples:
      | key       |
      | Control+k |
      | /         |

  @wide
  Scenario: Wide: Escape restores the search bar
    Given I use a wide device
    And the library is filtered by "insel"
    And I opened the palette by typing "a " in the empty search bar
    When I press Escape
    Then the palette closes
    And the focus is in the search bar
    And the search bar shows "insel"
    And the library is still filtered by "insel"

  # --- all devices ----------------------------------------------------------

  Scenario: Enter without a prefix searches the library
    Given the command palette is open
    When I type "pratchett" in the palette
    Then "Alle Ergebnisse für „pratchett“" is the first and selected entry
    When I press Enter
    Then the library shows the results for "pratchett"

  Scenario: Enter with a prefix takes the first hit
    Given the command palette is open
    When I type "a pratchett" in the palette
    Then "Terry Pratchett" is the selected entry
    When I press Enter
    Then the palette closes
    And the library is filtered by author "Terry Pratchett"

  Scenario: E-Ink: palette without animation and with large targets
    Given E-Ink mode is on
    When I open the command palette
    Then it appears without animation
    And every entry is at least 44 px high
