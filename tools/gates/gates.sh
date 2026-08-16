#!/usr/bin/env bash
# The one-command gate set: every gate in order, banners, non-zero
# propagation. A gate only reports PASS after running green once.
#
#   nix-shell --run "npm run gate"   (or: bash tools/gates/gates.sh)
#
# Note: gate-mutate intentionally runs LAST — it is the slowest.
set -euo pipefail
cd "$(dirname "$0")/../.."

run_gate() { # name script
  local name="$1" script="$2"
  echo ""
  echo "=== gate: $name ==="
  bash "$script"
  echo "PASS $name"
}

run_gate "check (native contract)" tools/gates/gate-check.sh
run_gate "ts-core seam (effects channel)" tools/gates/gate-ts.sh
run_gate "vault oracles (fast)" tools/gates/gate-vault.sh
run_gate "zig fmt" tools/gates/gate-zig.sh
run_gate "smoke sequence" tools/smoke/run.sh
run_gate "package smoke" tools/gates/gate-package.sh
run_gate "mutation (M1..M8)" tools/gates/gate-mutate.sh

echo ""
echo "ALL GATES PASS"