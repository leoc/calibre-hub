#!/usr/bin/env bash
# The reader in a real WebKit (README, Reader in Safari): nixpkgs' Playwright
# and its browsers, which go together, against the mock hub with the hub's
# policy. Mesa comes from the same nixpkgs: the one in /run/opengl-driver can
# be too new for the libgbm the browser is linked to, and WPE then has no EGL.
set -euo pipefail
cd "$(dirname "$0")/../.."
port=${E2E_PORT:-5175}

build() { nix build --inputs-from .. "nixpkgs#$1" --no-link --print-out-paths; }
core=$(build playwright-driver)
browsers=$(build playwright-driver.browsers)
mesa=$(build mesa)

HUB_CSP=1 pnpm exec vite --mode mock --port "$port" --strictPort &
server=$!
trap 'kill "$server"' EXIT
until curl -sf "http://localhost:$port/" > /dev/null; do sleep 0.2; done

__EGL_VENDOR_LIBRARY_FILENAMES=$mesa/share/glvnd/egl_vendor.d/50_mesa.json \
  LIBGL_ALWAYS_SOFTWARE=1 \
  PLAYWRIGHT_CORE=$core \
  WEBKIT=$(echo "$browsers"/webkit-*/pw_run.sh) \
  BASE_URL=http://localhost:$port \
  node e2e/webkit/reader.mjs
