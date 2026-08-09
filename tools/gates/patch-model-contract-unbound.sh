#!/usr/bin/env bash
# Merge viewUnbound from the TS frontend contract into
# zig-out/model-contract.zon. The compiled-core sidecar (scriptc
# co-emit) does not yet carry unbound lists; the frontend contract
# does. native check --strict reads the zon artifact.
set -euo pipefail
cd "$(dirname "$0")/../.."

ZON=zig-out/model-contract.zon
TMP=/tmp/kakuriyo-frontend-contract.json
SDK=vendor/native-sdk

[ -f "$ZON" ] || { echo "missing $ZON — run zig build model-contract first"; exit 1; }

node "$SDK/build/ts_run.mjs" "$SDK/packages/core/src/cli.ts" src/core.ts \
  --contract "$TMP" --contract-entry src/core.ts >/dev/null

python3 - "$TMP" "$ZON" <<'PYEOF'
import json, re, sys

contract_path, zon_path = sys.argv[1], sys.argv[2]
with open(contract_path) as f:
    c = json.load(f)
model = c.get("model_unbound", [])
msg = c.get("msg", {}).get("unbound", [])

with open(zon_path) as f:
    text = f.read()

def zon_list(names):
    if not names:
        return ".{}"
    return ".{ " + ", ".join(f'"{n}"' for n in names) + " }"

text = re.sub(
    r"\.model_unbound = \.[^,]*,",
    f".model_unbound = {zon_list(model)},",
    text,
    count=1,
)
text = re.sub(
    r"\.msg_unbound = \.[^,]*,",
    f".msg_unbound = {zon_list(msg)},",
    text,
    count=1,
)
with open(zon_path, "w") as f:
    f.write(text)
PYEOF
