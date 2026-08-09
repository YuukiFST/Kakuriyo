#!/usr/bin/env bash
# gate-check: the native CLI's own contract check (TS core types,
# app.native markup, stage wiring). Run: nix-shell --run
# "bash tools/gates/gate-check.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."
zig build model-contract >/dev/null
bash tools/gates/patch-model-contract-unbound.sh
native check --strict