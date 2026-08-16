#!/usr/bin/env bash
# gate-ts: TS core state machine + effects-channel binding oracles.
#
# Node harness runs outside the compiled lane (see
# .scratch/kakuriyo/research/ts-core-lane-limits.md). Zig suite
# still proves sendFn/requestFn at the binding level.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "gate-ts: tsc --noEmit"
npx tsc --noEmit

echo "gate-ts: node core harness (ts_run)"
npm run test:core

echo "gate-ts: zig binding oracles"
zig build test -Dplatform=null --summary all
