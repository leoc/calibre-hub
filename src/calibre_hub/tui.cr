require "./tui/app"

module CalibreHub
  # Terminal UI on the hub's API (`hub tui`), built on bubbletea.cr.
  module Tui
    def self.run(client : Cli::Client) : Nil
      # ask the terminal for its background now: once the program owns stdin
      # the answer would never arrive (adaptive colours, Glamour "auto")
      Lipgloss.dark_background?
      Tea::Program.new(App.new(ApiSource.new(client)), alt_screen: true).run
    end
  end
end
