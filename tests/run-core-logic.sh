#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node vendor/native-sdk/build/ts_run.mjs tests/core-logic.test.mjs
