# Keyboard control of the library, App mode (default) and Vim mode.
#
# Keys only act when the focus is not in an input, textarea, select or
# contenteditable. The "active book" has a visible focus ring; the grid
# moves by rows, the list by lines.
#
# Wide devices only (phones are unchanged). Given and Then steps are worded
# apart ("Given the first book is the active book" sets it up, "Then the
# active book is the first book" checks it), since playwright-bdd matches
# steps by text alone.

@wide
Feature: Keyboard control

  Background:
    Given I am logged in
    And I use a wide device
    And the library shows the grid with at least 3 rows of books

  # --- Phase 1: list, selection, commands ----------------------------------

  Scenario: The first key press activates the first book
    When I press "ArrowDown"
    Then the active book is the first book
    And the active book has a visible focus ring

  Scenario Outline: Moving in the grid
    Given keyboard mode is "<mode>"
    And the first book is the active book
    When I press "<down>"
    Then the active book is the first book of the second row
    When I press "<right>"
    Then the active book is the second book of the second row
    When I press "<up>"
    Then the active book is the second book of the first row
    When I press "<left>"
    Then the active book is the first book

    Examples:
      | mode | down      | right      | up      | left      |
      | app  | ArrowDown | ArrowRight | ArrowUp | ArrowLeft |
      | vim  | j         | l          | k       | h         |

  Scenario: Vim counts and jumps
    Given keyboard mode is "vim"
    And the first book is the active book
    When I type "3j"
    Then the active book is in the fourth row
    When I type "G"
    Then the last book of the page is the active book
    When I type "gg"
    Then the active book is the first book

  Scenario: App mode jumps
    Given keyboard mode is "app"
    And the first book is the active book
    When I press "End"
    Then the last book of the page is the active book
    When I press "Home"
    Then the active book is the first book

  Scenario Outline: Next and previous page
    Given keyboard mode is "<mode>"
    When I press "<next>"
    Then the library shows page 2
    And the active book is the first book
    When I press "<prev>"
    Then the library shows page 1

    Examples:
      | mode | next     | prev   |
      | app  | PageDown | PageUp |
      | vim  | ]        | [      |

  Scenario: Enter opens the detail, the next book is one key away
    Given keyboard mode is "vim"
    And the first book is the active book
    When I press "Enter"
    Then the detail of the first book is open
    When I press "j"
    Then the detail of the second book is open
    When I press "Escape"
    Then the detail is closed
    And the active book is the second book

  Scenario: Space selects, Shift extends
    Given keyboard mode is "app"
    And the first book is the active book
    When I press "Space"
    Then selection mode is on
    And 1 book is selected
    When I press "Shift+ArrowRight"
    And I press "Shift+ArrowRight"
    Then 3 books are selected
    When I press "Escape"
    Then no book is selected

  Scenario: Vim visual mode
    Given keyboard mode is "vim"
    And the first book is the active book
    When I type "v"
    Then visual mode is shown in the status line
    When I type "ll"
    Then 3 books are selected
    When I press "Escape"
    Then visual mode is off
    And 3 books are still selected

  Scenario: Select all on the page
    Given keyboard mode is "app"
    When I press "Control+a"
    Then all books of the page are selected

  Scenario: ">" opens the commands for the selection
    Given I selected 3 books
    When I type ">"
    Then the command palette opens in command mode
    And it offers "Tag hinzufügen (3)", "Kategorie setzen (3)" and "Löschen (3)"

  Scenario: ">" without a selection opens the general commands
    Given nothing is selected
    When I type ">"
    Then the command palette opens in command mode
    And it offers the general commands

  Scenario: "/" puts the focus into the search bar
    When I type "/"
    Then the focus is in the search bar
    When I type "pratchett"
    And I press "Enter"
    Then the library shows the results for "pratchett"
    And the first result is the active book
    And the focus is on the book list

  Scenario: Escape in the search bar returns to the list
    Given the third book is the active book
    When I type "/"
    And I press "Escape"
    Then the focus is on the book list
    And the active book is the third book

  Scenario: Keys do nothing while typing
    Given keyboard mode is "vim"
    And I am typing in the search bar
    When I type "jjk"
    Then the search bar contains "jjk"
    And the active book has not changed

  Scenario: Switching the mode
    Given keyboard mode is "app"
    When I run the command "Tastatur: Vim" in the command palette
    Then the keyboard mode setting shows "vim"
    And it is still "vim" after a reload

  # --- Phase 2: global, extras ----------------------------------------------

  Scenario Outline: History back and forward
    Given keyboard mode is "<mode>"
    And I opened the trash page from the library
    When I press "<back>"
    Then the library is shown
    When I press "<forward>"
    Then the trash page is shown

    Examples:
      | mode | back           | forward         |
      | app  | Alt+ArrowLeft  | Alt+ArrowRight  |
      | vim  | Shift+H        | Shift+L         |

  Scenario Outline: Goto sequences
    Given keyboard mode is "vim"
    When I type "<keys>"
    Then the <page> is shown

    Examples:
      | keys | page             |
      | gt   | trash page       |
      | gm   | metadata page    |
      | gv   | suggestions page |
      | gL   | lists page       |
      | gl   | library          |

  Scenario: Category tree with the keyboard
    Given keyboard mode is "vim"
    When I type "gc"
    Then the focus is in the category tree
    When I type "j"
    And I press "Enter"
    Then the library is filtered by the second category

  Scenario: Hint mode opens a target
    Given keyboard mode is "vim"
    When I type "f"
    Then every book and link shows a short hint label
    When I type the hint of the third book
    Then the detail of the third book is open

  Scenario: Hint mode selects
    Given keyboard mode is "vim"
    When I type "F"
    And I type the hint of the second book
    Then the second book is selected

  Scenario Outline: Direct keys on the active book
    Given keyboard mode is "vim"
    And the first book is the active book
    When I type "<keys>"
    Then <result>

    Examples:
      | keys | result                                         |
      | e    | the edit form of the first book is open        |
      | t    | the first book's reading list toggle flips     |
      | dd   | a delete confirmation for the first book opens |
      | y    | the link to the first book is in the clipboard |

  Scenario Outline: Saving the active book to the list used last, and back out
    Given keyboard mode is "<mode>"
    And the first book is the active book
    When I press "<save>"
    Then the browser did not handle the key itself
    And the first book is in the list "Urlaub"
    When I press "<save>"
    Then the first book is not in the list "Urlaub"
    And a toast says "1 Buch aus Urlaub entfernt"

    Examples:
      | mode | save      |
      | app  | Control+s |
      | vim  | s         |

  Scenario: "s" saves the selection to the list used last
    Given keyboard mode is "vim"
    And I selected 3 books
    When I type "s"
    Then the 3 selected books are in the list "Urlaub"

  Scenario Outline: "S" opens the save dialog for the active book
    Given keyboard mode is "<mode>"
    And the first book is the active book
    When I press "<dialog>"
    Then the dialog "In Listen speichern" opens for the first book

    Examples:
      | mode | dialog          |
      | app  | Control+Shift+S |
      | vim  | Shift+S         |

  Scenario: Help overlay
    When I type "?"
    Then an overlay lists the keys of the current mode
    When I press "Escape"
    Then the overlay is closed

  Scenario: Own key bindings
    Given keyboard mode is "vim"
    And I bind "next book" to "n" in the settings
    And the first book is the active book
    When I type "n"
    Then the active book moves down by one row

  # --- Phase 3: commands on the selection and the active book -----------------
  # The palette's commands act on the selection (or all matches), else the
  # active book, else the open detail; the command names its target:
  # "Tag hinzufügen (3)" or "Tag hinzufügen: <title>". A value can be typed
  # right after the command ("tag Noten") or picked in a second step. Field
  # changes apply at once with "Rückgängig"; deleting and runs over more than
  # 50 books ask first.

  Scenario: A command with its value typed directly, then undone
    Given I selected 3 books
    When I type ">"
    And I type "tag Noten"
    Then "Neu: Tag ‚Noten‘ hinzufügen (3)" is the first and selected entry
    When I press "Enter"
    Then the palette closes
    And a toast says "Erledigt: Tag ‚Noten‘ hinzufügen (3)"
    And the 3 selected books have the tag "Noten"
    When I click "Rückgängig" in the toast
    Then a message says "Rückgängig gemacht: Tag ‚Noten‘ hinzufügen (3)"
    And no selected book has the tag "Noten"

  Scenario: Picking the value in a second step, for the active book
    Given nothing is selected
    And the second book is the active book
    When I type ">"
    And I type "Tag hinzufügen"
    Then the selected entry is "Tag hinzufügen" for the active book
    When I press "Enter"
    Then the palette asks for a value of "Tag hinzufügen"
    When I type "geschenk"
    And I press "Enter"
    Then the palette closes
    And the active book has the tag "geschenk"

  Scenario: Adding the selection to a list typed in the palette
    Given I selected 2 books
    When I type ">"
    And I type "zu liste klass"
    Then "Zu Liste ‚Klassiker‘ (2)" is the first and selected entry
    When I press "Enter"
    Then a toast says "2 zu Klassiker hinzugefügt"
    And the 2 selected books are in the list "Klassiker"

  Scenario: Deleting the active book from the palette asks first
    Given nothing is selected
    And the first book is the active book
    When I type ">"
    And I type "Löschen"
    And I press "Enter"
    Then the palette asks to delete the active book
    When I press "Enter"
    Then a message says "1 in den Papierkorb verschoben"
    And the active book is gone from the library

  Scenario: A change of more than 50 books asks first
    Given I selected all matches
    When I type ">"
    And I type "tag Noten"
    And I press "Enter"
    Then the palette asks to change all matches
    When I press "ArrowDown"
    And I press "Enter"
    Then "Neu: Tag ‚Noten‘ hinzufügen" is offered for all matches again
