#!/usr/bin/env bash
# calibre-server's preStart and ExecStart of nix/module.nix, in the sandbox.
# Environment as there (LIBRARY, USERDB, COLUMNS, HIERARCHICAL) plus USERS and
# CALIBRE_SERVER, the module's command line.
set -euo pipefail
bash /run/calibre-hub/init.sh
/run/calibre-hub/bin/calibre-hub install-triggers "$LIBRARY/metadata.db"
# shellcheck disable=SC2086 # a command line
exec $CALIBRE_SERVER
