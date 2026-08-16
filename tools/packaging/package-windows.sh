#!/usr/bin/env bash
# Win11 packaging scaffold — produces a directory distributable when run on
# Windows or when cross-packaging is available. On Linux CI this only verifies
# the scaffold script and documents the target path.
set -euo pipefail
cd "$(dirname "$0")/../../"

WIN_DIR="zig-out/package/kakuriyo-windows"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "== package windows (host) =="
    native package --target windows
    test -d "$WIN_DIR"
    test -f "$WIN_DIR/package-manifest.zon"
    echo "PASS package-windows"
    ;;
  *)
    echo "== package windows scaffold (skipped on $(uname -s)) =="
    echo "Run on Win11: native package --target windows"
    echo "Expected output: $WIN_DIR/"
    echo "PASS package-windows-scaffold"
    ;;
esac
