# `hub`: the command line client and the TUI. A binary of its own so that
# only it links bubbletea.cr (and its Go library), not the server.
require "./calibre_hub/cli"
require "./calibre_hub/tui"

CalibreHub::Cli.tui = ->(client : CalibreHub::Cli::Client) { CalibreHub::Tui.run(client) }
exit CalibreHub::Cli.run(ARGV)
