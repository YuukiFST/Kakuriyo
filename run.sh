#!/usr/bin/env bash
# Launch Kakuriyo for manual testing (GTK window + markup hot reload).
#
#   ./run.sh
#   npm start
#
# Needs a display (DISPLAY / WAYLAND_DISPLAY). Re-enters nix-shell when
# outside it so Zig/GTK/Node match shell.nix.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "error: no DISPLAY/WAYLAND_DISPLAY — open a graphical session first" >&2
  exit 1
fi

if ! command -v native >/dev/null 2>&1; then
  echo "error: 'native' CLI not on PATH (install @native-sdk/cli or link vendor CLI)" >&2
  exit 1
fi

run_dev() {
  echo "Kakuriyo: building Debug + launching (Ctrl+C to quit)…"
  exec native dev
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_dev
fi

if ! command -v nix-shell >/dev/null 2>&1; then
  echo "warning: nix-shell missing — running native dev with host env" >&2
  run_dev
fi

exec nix-shell --run "native dev"
