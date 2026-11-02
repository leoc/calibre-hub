# Reading in the browser (foliate-js), /read/:id.
#
# The mocks serve every book file as a small EPUB with three chapters
# ("Kapitel 1" to "Kapitel 3"), PDFs as a three-page PDF. The reading
# position is saved per device; another device is simulated by saving a
# position through the API with another device id. Offline is Playwright's
# context.setOffline; the mocks then fail /api/ like the network would (the
# service worker that keeps the app itself offline runs in builds only).

Feature: Reading

  Background:
    Given I am logged in

  Scenario: Opening a book from the detail
    Given the detail of a book with the format "EPUB" is open
    When I click the link "Lesen" in the detail
    Then the reader shows the first page
    And the reader shows the chapter "Kapitel 1"

  Scenario: Turning pages with the keyboard
    Given the reader is open for a book with the format "EPUB"
    When I press "ArrowRight" in the reader 3 times
    Then the reading progress is above 0 %
    When I press "ArrowLeft" in the reader 3 times
    Then the reader shows the first page

  Scenario: The position is saved and restored
    Given the reader is open for a book with the format "EPUB"
    When I press "PageDown" in the reader 4 times
    Then this device's position is saved
    When I press "Escape" in the reader
    Then the detail offers to continue at the saved percentage
    When I click the continue button in the detail
    Then the reader shows the book at the saved percentage

  Scenario: Continuing where another device stopped
    Given the reader is open for a book with the format "EPUB"
    And I press "PageDown" in the reader 1 times
    And this device's position is saved
    And I press "Escape" in the reader
    And the device "Boox" saved the position 71 % for the book
    When I click the continue button in the detail
    Then the reader asks "Auf Boox bei 71 % – dort weiterlesen?"
    When I click "Dort weiterlesen" in the reader
    Then the reading progress is above 50 %

  Scenario: Reading a PDF
    Given the reader is open for a book with the format "PDF"
    Then the reader shows the book at 33 %
    When I press "ArrowRight" in the reader 1 times
    Then the reading progress is above 50 %

  Scenario: E-Ink: tap zones instead of swiping
    Given E-Ink mode is on
    And the reader is open for a book with the format "EPUB"
    Then the reader's toolbar is hidden
    When I tap the right third of the page
    Then the reading progress is above 0 %
    When I tap the left third of the page
    Then the reader shows the first page
    When I tap the middle of the page
    Then the reader's toolbar is shown

  Scenario: Making a book available offline
    Given the detail of a book with the format "EPUB" is open
    When I make the book available offline
    Then the detail shows the book as available offline with its size
    When I click "Offline entfernen" in the detail
    Then the detail offers to make the book available offline

  Scenario: Reading offline, the position is synced on reconnect
    Given the reader is open for a book with the format "EPUB"
    And I press "Escape" in the reader
    And I make the book available offline
    When the connection is lost
    Then the app shows that it is offline
    When I open the reader from the detail
    And I press "PageDown" in the reader 3 times
    Then the reader shows that it is offline
    And this device's position waits for the connection
    When the connection is back
    Then the hub has this device's position from offline

  # Reader settings: per account (GET/PUT /api/reader/settings), applied
  # while the settings are open. The mock book sets its own sizes and line
  # height (p.text { font-size: small; line-height: 1.2 }), like many
  # publishers do.

  Scenario: The font size also changes text the book sizes itself
    Given the reader is open for a book with the format "EPUB"
    When I open the reader settings
    And I click "Schrift größer" in the reader settings 2 times
    Then the book's text is larger than before
    When I click "Schrift kleiner" in the reader settings 4 times
    Then the book's text is smaller than at first

  Scenario: The settings are kept for the account
    Given the reader is open for a book with the format "EPUB"
    When I open the reader settings
    And I choose "Sepia" for "Farben" in the reader settings
    And I choose "Literata" for "Schriftart" in the reader settings
    Then the page is shown in sepia
    And the book's text is set in "Literata"
    And the hub has the reader setting "theme" as "sepia"
    When I open the book in the reader again
    Then the page is shown in sepia
    And the book's text is set in "Literata"

  Scenario: Overriding the book's style
    Given the reader is open for a book with the format "EPUB"
    When I open the reader settings
    Then the book's paragraphs have the line height 1.2
    When I turn on "Buchstil überschreiben" in the reader settings
    Then the book's paragraphs have the line height 1.5

  Scenario: Columns, scrolling and the page-turn animation
    Given the reader is open for a book with the format "EPUB"
    Then the book is shown with up to 2 columns, paginated and animated
    When I open the reader settings
    And I choose "Eine" for "Spalten" in the reader settings
    And I choose "Fortlaufend" for "Anzeige" in the reader settings
    And I turn off "Animation beim Blättern" in the reader settings
    Then the book is shown with up to 1 columns, scrolled and not animated

  Scenario: E-Ink: no page-turn animation, black on white
    Given E-Ink mode is on
    And the reader is open for a book with the format "EPUB"
    When I tap the middle of the page
    And I open the reader settings
    Then the reader settings offer no animation and no colors
    And the book is shown with up to 2 columns, paginated and not animated
