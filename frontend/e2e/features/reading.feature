# Reading in the browser (foliate-js), /read/:id.
#
# The mocks serve every book file as a small EPUB with three chapters
# ("Kapitel 1" to "Kapitel 3"), PDFs as a three-page PDF. The reading
# position is saved per device; another device is simulated by saving a
# position through the API with another device id.

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
