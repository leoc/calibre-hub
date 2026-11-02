# calibre-hub-triggers <metadata.db>: same as `calibre-hub install-triggers`,
# built on its own (nix/triggers.nix) from library_db.cr only. calibre-server
# runs it in preStart, so its unit changes, and restarts, only when the
# triggers do, not with every hub release.
require "./calibre_hub/library_db"

case ARGV.first?
when "--help", "-h"
  puts "usage: calibre-hub-triggers <metadata.db>   (only while calibre-server is stopped)"
when String
  CalibreHub::LibraryDB.install_triggers(ARGV.first)
  puts "triggers installed in #{ARGV.first}"
else
  abort "usage: calibre-hub-triggers <metadata.db>"
end
