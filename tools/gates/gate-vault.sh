#!/usr/bin/env bash
# gate-vault: the vault envelope + host dispatch oracles (std-only,
# GTK-free — the fast loop).
set -euo pipefail
cd "$(dirname "$0")/../.."
zig build test-vault --summary all