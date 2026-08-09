#!/usr/bin/env bash
# gate-ts: the TS-core seam over the effects channel.
#
# RE-SCOPED from the plan (documented in
# .scratch/kakuriyo/research/ts-core-lane-limits.md): the scriptc
# compiled lane of @native-sdk/cli 0.8.3 cannot sustain request-routed
# or allocating updates, so the core is the fire-and-forget ping core
# and the round trip is proven at the binding level (sendFn/requestFn
# oracles in the app suite). This gate runs that suite; the node core
# harness from the plan is replaced by it.
set -euo pipefail
cd "$(dirname "$0")/../.."
zig build test -Dplatform=null --summary all