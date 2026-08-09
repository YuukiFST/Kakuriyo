#!/usr/bin/env bash
# gate-zig: formatting hygiene for every Zig source in the repo.
set -euo pipefail
cd "$(dirname "$0")/../.."
zig fmt --check build.zig build build.zig.zon src