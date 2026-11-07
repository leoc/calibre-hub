# Shared by dev/mock, dev/up, dev/down and dev/reset; see README, Development.
#
# Everything of a branch lives in $DEV_ROOT/<slug>/, nothing else is written:
#
#   offset        the branch's ports (see ports)
#   worktree/     a checkout, when the branch had none
#   credentials/  dev logins and the session key, made on first start
#   ebooks/       /srv/media/ebooks in the sandbox: calibre/, backlog/, inbox/, ...
#   var/          /var/lib in the sandbox: calibre-hub/, calibre-server/
#   tmp/          /tmp in the sandbox
#   run/          pid files, the hub's environment, the flags of the last start
#   log/          calibre-server.log, hub.log, vite.log, mock.log
#
# $DEV_ROOT/.cache holds what branches share: tools, demo files, Crystal's cache.

DEV_ROOT=${CALIBRE_HUB_DEV_ROOT:-$HOME/_nobackup/calibre-hub-dev}
DEV_CACHE=$DEV_ROOT/.cache
DEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$DEV_DIR")
# shmoz in the tailnet: the only address besides 127.0.0.1 a dev hub takes
DEVICES_IP=100.64.0.2
# the nixos-config that says what dmt runs on
NIXOS_CONFIG=${CALIBRE_HUB_DEV_NIXOS_CONFIG:-$HOME/.nixos-config}

say() { printf '%s\n' "$*"; }
die() {
  printf 'dev: %s\n' "$*" >&2
  exit 1
}

# --- branches ----------------------------------------------------------------

current_branch() {
  git -C "$REPO" symbolic-ref --quiet --short HEAD || git -C "$REPO" rev-parse --short HEAD
}

# a directory name, different for two branches that read the same as one
slug_of() {
  local plain
  plain=$(printf %s "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
  if [ "$plain" = "$1" ]; then
    printf %s "$plain"
  else
    printf '%s-%s' "$plain" "$(printf %s "$1" | sha1sum | cut -c1-4)"
  fi
}

# the worktree that has the branch checked out, empty when none has
worktree_of() {
  git -C "$REPO" worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $1 == "branch" && $2 == ref { print path }'
}

# Sets BRANCH, SLUG, STATE and WT. A branch without a worktree gets one in its
# state directory, the checkouts of other sessions stay as they are.
use_branch() {
  BRANCH=${1:-$(current_branch)}
  SLUG=$(slug_of "$BRANCH")
  STATE=$DEV_ROOT/$SLUG
  if [ -z "${1:-}" ]; then
    WT=$REPO
    return
  fi
  WT=$(worktree_of "$BRANCH")
  [ -n "$WT" ] && return
  [ -d "$STATE/worktree" ] && {
    WT=$STATE/worktree
    return
  }
  git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || die "no branch $BRANCH"
  mkdir -p "$STATE"
  git -C "$REPO" worktree add --quiet "$STATE/worktree" "$BRANCH"
  WT=$STATE/worktree
}

# --- ports -------------------------------------------------------------------

busy() { [ -n "$(ss -Hltn "sport = :$1")" ]; }

# The branch's name gives its ports. Only when they are taken, by a port of
# another program or another branch, it moves on; `offset` keeps the result,
# so a branch has the same ports from then on.
PORT_RANGE=400
ports() {
  local file=$STATE/offset n
  mkdir -p "$STATE"
  if [ ! -f "$file" ]; then
    n=$(($(printf %s "$BRANCH" | cksum | cut -d' ' -f1) % PORT_RANGE))
    while port_taken "$n"; do n=$(((n + 1) % PORT_RANGE)); done
    printf '%s\n' "$n" >"$file"
  fi
  n=$(<"$file")
  MOCK_PORT=$((5200 + n))
  VITE_PORT=$((5700 + n))
  HUB_PORT=$((8200 + n))
  CALIBRE_PORT=$((18200 + n))
}

port_taken() {
  local n=$1 other p
  for other in "$DEV_ROOT"/*/offset; do
    [ -f "$other" ] && [ "$(<"$other")" = "$n" ] && return 0
  done
  for p in $((5200 + n)) $((5700 + n)) $((8200 + n)) $((18200 + n)); do
    busy "$p" && return 0
  done
  return 1
}

# --- processes ---------------------------------------------------------------

# Each runs in a session of its own: stopping it takes everything it started.
start_bg() { # <name> <log> <command...>
  local name=$1 log=$2
  shift 2
  mkdir -p "$STATE/run" "$(dirname "$log")"
  setsid "$@" </dev/null >>"$log" 2>&1 &
  printf '%s\n' "$!" >"$STATE/run/$name.pid"
}

running() { # <name>
  local file=$STATE/run/$1.pid pid
  [ -f "$file" ] || return 1
  pid=$(<"$file")
  [ -n "$pid" ] && [ "$(ps -o sid= -p "$pid" | tr -d ' ')" = "$pid" ]
}

stop_bg() { # <name>
  local name=$1 pid i
  if running "$name"; then
    pid=$(<"$STATE/run/$name.pid")
    kill -TERM -- "-$pid" 2>/dev/null || true
    for i in $(seq 1 50); do
      [ -n "$(ps -o pid= -s "$pid")" ] || break
      sleep 0.2
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    say "stopped $name"
  fi
  rm -f "$STATE/run/$name.pid"
}

wait_for() { # <what> <seconds> <log> <test command...>
  local what=$1 seconds=$2 log=$3 i
  shift 3
  for i in $(seq 1 "$((seconds * 2))"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  tail -n 30 "$log" >&2 || true
  die "$what did not come up, see $log"
}

# --- frontend ----------------------------------------------------------------

node_modules() { # in the worktree's frontend
  [ -d "$WT/frontend/node_modules" ] && [ "$WT/frontend/node_modules/.modules.yaml" -nt "$WT/frontend/pnpm-lock.yaml" ] && return
  (cd "$WT/frontend" && pnpm install --frozen-lockfile --prefer-offline --silent)
}

# --- tools and sandbox -------------------------------------------------------

# The nixpkgs of dmt, from nixos-config's lock; the repo's own without one
pinned_nixpkgs() {
  local lock=$NIXOS_CONFIG/flake.lock rev=
  [ -f "$lock" ] && rev=$(jq -r '.nodes["nixpkgs-stable"].locked.rev // empty' "$lock")
  if [ -z "$rev" ]; then
    rev=$(jq -r '.nodes.nixpkgs.locked.rev' "$REPO/flake.lock")
    say "dev: no nixos-config at $NIXOS_CONFIG, calibre comes from this flake's nixpkgs" >&2
  fi
  printf %s "$rev"
}

# Sets NIXPKGS_REV and TOOLS: bin/ with calibre and everything else of the sandbox
tools() {
  NIXPKGS_REV=$(pinned_nixpkgs)
  local key link
  key=$(cat "$DEV_DIR/tools.nix" | sha1sum | cut -c1-8)
  link=$DEV_CACHE/tools-${NIXPKGS_REV:0:12}-$key
  if [ ! -e "$link" ]; then
    mkdir -p "$DEV_CACHE"
    say "dev: building the tools from nixpkgs ${NIXPKGS_REV:0:12}"
    nix build --impure --out-link "$link" --expr "
      let pkgs = (builtins.getFlake \"github:NixOS/nixpkgs/$NIXPKGS_REV\").legacyPackages.\${builtins.currentSystem};
      in import $DEV_DIR/tools.nix { inherit pkgs; }"
  fi
  TOOLS=$(readlink -f "$link")
}

# What nix/module.nix of the branch says, dmt's settings in it (dev/hub-env.nix)
module_json() {
  local key file
  key=$(cat "$WT/nix/module.nix" "$DEV_DIR/hub-env.nix" | sha1sum | cut -c1-12)
  file=$DEV_CACHE/module-${NIXPKGS_REV:0:12}-$key.json
  if [ ! -f "$file" ]; then
    say "dev: reading nix/module.nix" >&2
    nix eval --impure --json --expr "
      let nixpkgs = builtins.getFlake \"github:NixOS/nixpkgs/$NIXPKGS_REV\";
      in import $DEV_DIR/hub-env.nix {
        inherit nixpkgs;
        pkgs = nixpkgs.legacyPackages.\${builtins.currentSystem};
        module = $WT/nix/module.nix;
      }" >"$file.new"
    mv "$file.new" "$file"
  fi
  cat "$file"
}

# A unit's environment, KEY=value, each ended by a NUL
module_env() { # hub | server
  module_json | jq -j --arg unit "$1" '.[$unit] | to_entries[] | select(.key != "PATH") | "\(.key)=\(.value)\u0000"'
}

# Sets SANDBOX, the start of a command line: run with further bwrap arguments,
# then -- and what to run. In place of the systemd unit on dmt: everything
# read-only, /home and the rest of the host gone, the state directory mounted
# where dmt has these paths. An own user id too: calibre allows one program per
# user and machine (an abstract socket named after the uid), so each branch is
# a user of its own there, and calibre Desktop on the host doesn't notice. On
# the host all of it is still Arthur. No environment comes along.
sandbox() {
  mkdir -p "$STATE/tmp"
  SANDBOX=(
    "$TOOLS/bin/bwrap"
    --unshare-user --uid "$((20000 + $(<"$STATE/offset")))"
    --unshare-pid --unshare-ipc --unshare-uts --hostname calibre-hub-dev
    --ro-bind /nix/store /nix/store --ro-bind /etc /etc
    --ro-bind /bin /bin --ro-bind /usr/bin /usr/bin
    --proc /proc --dev /dev --tmpfs /run --ro-bind-try /run/nscd /run/nscd
    --tmpfs /var
    --bind "$STATE/tmp" /tmp
    --clearenv --setenv PATH "$TOOLS/bin" --setenv LANG C.UTF-8
    --setenv QT_QPA_PLATFORM offscreen
  )
}
