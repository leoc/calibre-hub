require "./tui/app"

module CalibreHub
  # Terminal UI on the hub's API (`hub tui`), built on bubbletea.cr.
  module Tui
    def self.run(client : Cli::Client) : Nil
      # ask the terminal for its background now: once the program owns stdin
      # the answer would never arrive (adaptive colours, Glamour "auto")
      Lipgloss.dark_background?
      app = App.new(ApiSource.new(client))
      app.history_file = history_file(ENV.to_h)
      Tea::Program.new(app, alt_screen: true).run
    end

    # the `:` history: $XDG_STATE_HOME/calibre-hub/tui-history
    def self.history_file(env : Hash(String, String)) : String?
      state = env["XDG_STATE_HOME"]?.presence || env["HOME"]?.presence.try { |h| File.join(h, ".local", "state") }
      state.try { |s| File.join(s, "calibre-hub", "tui-history") }
    end
  end
end
