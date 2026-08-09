#!/usr/bin/env bash
# gate-mutate: the M1..M8 mutation gate for the vault envelope.
# Every mutant must kill at least one oracle; a survivor exits 1.
# Slow (~3.5 min): run it in CI and before release, not on every edit.
set -euo pipefail
cd "$(dirname "$0")/../.."
bash tools/gates/mutate.sh