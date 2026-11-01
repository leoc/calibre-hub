#!/usr/bin/env bash
# Testbibliothek + calibre-server fuer die Entwicklung.
# Nutzung: dev/testlib.sh <dir>   (legt <dir>/library, <dir>/users.sqlite an,
# startet calibre-server auf 127.0.0.1:18083 mit Nutzer hub/hub)
set -euo pipefail
dir=${1:?Verzeichnis}
lib=$dir/library userdb=$dir/users.sqlite
export QT_QPA_PLATFORM=offscreen
mkdir -p "$dir/src"
if [ ! -f "$lib/metadata.db" ]; then
  calibredb --with-library "$lib" list >/dev/null
  calibredb --with-library "$lib" add_custom_column kategorie Kategorie text >/dev/null
  i=0
  for b in "Douglas Adams|Per Anhalter durch die Galaxis|Anhalter|1|Roman.SciFi" \
           "Douglas Adams|Das Restaurant am Ende des Universums|Anhalter|2|Roman.SciFi" \
           "Martin Fowler|Refactoring||0|Fachbuch.Software" \
           "Eric Evans|Domain-Driven Design||0|Fachbuch.Software.Architektur"; do
    IFS='|' read -r author title series idx kat <<<"$b"
    i=$((i + 1))
    printf '%s\n\n%s\n' "$title" "Testinhalt $i" >"$dir/src/book$i.txt"
    ebook-convert "$dir/src/book$i.txt" "$dir/src/book$i.epub" --title "$title" --authors "$author" >/dev/null
    id=$(calibredb --with-library "$lib" add "$dir/src/book$i.epub" | grep -o '[0-9]\+$')
    [ -n "$series" ] && calibredb --with-library "$lib" set_metadata "$id" -f series:"$series" -f series_index:"$idx" >/dev/null
    calibredb --with-library "$lib" set_custom kategorie "$id" "$kat" >/dev/null
  done
fi
calibre-server --userdb "$userdb" --manage-users -- list | grep -qx hub \
  || calibre-server --userdb "$userdb" --manage-users -- add hub < <(printf %s hub) >/dev/null
calibre-server --userdb "$userdb" --manage-users -- chpass hub < <(printf %s hub) >/dev/null
# changelog triggers, like the NixOS module does before every start
here=$(dirname "$0")/..
[ -x "$here/bin/calibre-hub" ] && "$here/bin/calibre-hub" install-triggers "$lib/metadata.db"
exec calibre-server --userdb "$userdb" --enable-auth --auth-mode basic \
  --listen-on 127.0.0.1 --port 18083 "$lib"
