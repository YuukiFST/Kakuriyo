#!/usr/bin/env bash
# Headless oracles for the UI redesign flows. Exits non-zero if the
# required tests are missing or zig build test fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "UI-REDESIGN SMOKE FAIL: $1"
  exit 1
}

grep -q 'ingest many urls does not overflow tree rows' src/app_runner/app_tree_cap_tests.zig || fail "missing tree-row overflow oracle"
grep -q 'ingest many urls paints under widget node budget' src/app_runner/app_tree_cap_tests.zig || fail "missing ingest paint node oracle"
grep -q 'emitDisplayList' src/app_runner/app_tree_cap_tests.zig || fail "missing ingest paint emit oracle"
grep -q 'formatExtractedUrls splits glued urls one per line' src/vault/domain.zig || fail "missing glued-url extract oracle"
grep -q 'ingestUrls splits glued urls and strips trailing punctuation' src/vault/domain.zig || fail "missing ingestUrls glued oracle"
grep -q 'passwordMeetsSenhasPolicy' src/vault/domain.zig || fail "missing senhas policy"
grep -q 'preview_fetch_count' src/app_runner/app_controller.zig || fail "missing fetch-count select SLA hook"
grep -q 'ingestUrls' src/vault/domain.zig || fail "missing ingestUrls"
grep -q 'og:image' src/vault/preview.zig || fail "missing og:image parse"

if [ "${SKIP_TESTS:-}" != "1" ]; then
  echo "== ui-redesign controller + vault oracles =="
  zig build test -Dplatform=null --summary all || fail "zig build test -Dplatform=null"
  zig build test-vault --summary all || fail "zig build test-vault"
fi

echo "PASS ui-redesign: create/unlock, ingest hosts, cache-first select, senhas gate, lock clears gate"
