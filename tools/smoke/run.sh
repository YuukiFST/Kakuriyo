#!/usr/bin/env bash
# Kakuriyo vault v1 smoke: the goal's objective sequence against a REAL
# file with real crypto, with the produced bytes asserted on disk.
#
# Run from inside the repo's nix shell:
#   nix-shell --run "bash tools/smoke/run.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."

SMOKE_DIR="$(mktemp -d /tmp/kakuriyo-smoke-XXXXXX)"
SMOKE_VAULT="$SMOKE_DIR/vault.kakuriyo"
trap 'rm -rf "$SMOKE_DIR"' EXIT

fail() {
  echo "SMOKE FAIL: $1"
  exit 1
}

echo "== [1/3] vault envelope unit oracles =="
zig build test-vault --summary all || fail "zig build test-vault"

echo "== [2/3] app round-trip suite (effects channel + bindings) =="
zig build test -Dplatform=null --summary all || fail "zig build test -Dplatform=null"

echo "== [3/4] smoke sequence on a real vault file =="
OUT="$(zig build smoke-driver -- "$SMOKE_VAULT" 2>&1)" || fail "smoke driver exited non-zero"
printf '%s\n' "$OUT" | grep -E "^PASS" || fail "no PASS lines from the smoke driver"

# Every objective item from the DONE WHEN list must be a PASS line.
for line in \
  "PASS create" \
  "PASS unlock-first" \
  "PASS save" \
  "PASS lock" \
  "PASS re-unlock-read" \
  "PASS wrong-password" \
  "PASS rewrap-no-reencrypt" \
  "PASS password-rotation"; do
  printf '%s\n' "$OUT" | grep -qF "$line" || fail "missing smoke line: $line"
done

# File-level assertions (bash + od/xxd, no Zig): the v1 header.
[ -f "$SMOKE_VAULT" ] || fail "vault file was not produced"
MAGIC="$(od -An -tx1 -N4 "$SMOKE_VAULT" | tr -d ' \n')"
[ "$MAGIC" = "4b414b55" ] || fail "magic is not KAKU: $MAGIC"
VERSION_HEX="$(od -An -tx1 -j4 -N4 "$SMOKE_VAULT" | tr -d ' \n')"
[ "$VERSION_HEX" = "00000001" ] || fail "version is not 1 (be): $VERSION_HEX"
SIZE="$(stat -c %s "$SMOKE_VAULT")"
[ "$SIZE" -ge 148 ] || fail "file shorter than header+tag: $SIZE"

echo "SMOKE PASS: create + unlock + save + lock + re-unlock-read + wrong-password + rewrap-no-reencrypt + password-rotation (file: $SIZE bytes, magic+version verified on disk)"

echo "== [4/4] ui redesign headless oracles =="
SKIP_TESTS=1 bash tools/smoke/ui-redesign.sh || fail "ui-redesign smoke"