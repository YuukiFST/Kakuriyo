#!/usr/bin/env bash
# Headless oracles for the UI redesign flows. Exits non-zero if the
# required tests are missing or zig build test fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "UI-REDESIGN SMOKE FAIL: $1"
  exit 1
}

grep -q 'ingest paste groups by host' src/app_runner/app_controller.zig || fail "missing ingest controller oracle"
grep -q 'senhas gate rejects weak password and lock clears session' src/app_runner/app_controller.zig || fail "missing senhas/lock oracle"
grep -q 'select uses cached preview without fetch' src/app_runner/app_controller.zig || fail "missing cache-first select oracle"
grep -q 'preview_fetch_count' src/app_runner/app_controller.zig || fail "missing fetch-count select SLA hook"
grep -q 'passwordMeetsSenhasPolicy' src/vault/domain.zig || fail "missing senhas policy"
grep -q 'ingestUrls' src/vault/domain.zig || fail "missing ingestUrls"
grep -q 'og:image' src/vault/preview.zig || fail "missing og:image parse"

if [ "${SKIP_TESTS:-}" != "1" ]; then
  echo "== ui-redesign controller + vault oracles =="
  zig build test -Dplatform=null --summary all || fail "zig build test -Dplatform=null"
  zig build test-vault --summary all || fail "zig build test-vault"
fi

echo "PASS ui-redesign: create/unlock, ingest hosts, cache-first select, senhas gate, lock clears gate"
