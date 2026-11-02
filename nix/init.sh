# Prepares the library before calibre-server starts (nobody else has it open
# then): creates it, adds custom columns, marks hierarchical categories,
# keeps the trash forever and sets the users of calibre-server.
#
# Environment:
#   LIBRARY       path of the library
#   USERDB        calibre-server user database
#   COLUMNS       one "label|name|type" per line
#   HIERARCHICAL  space separated categories, e.g. "tags #kategorie"
#   USERS         one "name|password file" per line (trailing newlines are dropped)
set -euo pipefail

if [ ! -f "$LIBRARY/metadata.db" ]; then
  calibredb --with-library "$LIBRARY" list >/dev/null
fi

existing=$(calibredb --with-library "$LIBRARY" custom_columns | sed 's/ (.*//')
while IFS='|' read -r label name type; do
  [ -n "$label" ] || continue
  if ! grep -qx "$label" <<<"$existing"; then
    calibredb --with-library "$LIBRARY" add_custom_column "$label" "$name" "$type"
  fi
done <<<"$COLUMNS"

LIBRARY=$LIBRARY HIERARCHICAL=$HIERARCHICAL calibre-debug -c "
import os
from calibre.library import db
api = db(os.environ['LIBRARY']).new_api
cats = list(api.pref('categories_using_hierarchy', []))
for c in os.environ['HIERARCHICAL'].split():
    if c not in cats:
        cats.append(c)
api.set_pref('categories_using_hierarchy', cats)
# calibre expires trash entries older than this (at least one day, 0 empties
# the trash on close); deleted books stay until someone empties the trash
api.set_pref('expire_old_trash_after', 100 * 365 * 86400)
"

users=$(calibre-server --userdb "$USERDB" --manage-users -- list)
while IFS='|' read -r user file; do
  [ -n "$user" ] || continue
  if grep -qx "$user" <<<"$users"; then
    calibre-server --userdb "$USERDB" --manage-users -- chpass "$user" < <(printf %s "$(<"$file")") >/dev/null
  else
    calibre-server --userdb "$USERDB" --manage-users -- add "$user" < <(printf %s "$(<"$file")") >/dev/null
  fi
done <<<"$USERS"
