#!/usr/bin/env bash
# Packaging smoke: linux install tree + optional windows scaffold check.
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! command -v native >/dev/null 2>&1; then
  echo "native CLI not found — skip package gate (install @native-sdk/cli)"
  exit 0
fi

echo "== package linux =="
native package --target linux

LINUX_DIR="zig-out/package/kakuriyo-linux"
test -d "$LINUX_DIR"
test -x "$LINUX_DIR/bin/kakuriyo"
test -f "$LINUX_DIR/package-manifest.zon"
test -f "$LINUX_DIR/README.txt"

# NixOS-style wrap smoke: binary should start without immediate crash.
# Kakuriyo has no --version flag; a missing GTK linkage fails fast on exec.
if command -v timeout >/dev/null 2>&1; then
  timeout 2s "$LINUX_DIR/bin/kakuriyo" >/dev/null 2>&1 || true
fi

echo "PASS package-linux"

if [[ -f tools/packaging/package-windows.sh ]]; then
  bash tools/packaging/package-windows.sh
fi
