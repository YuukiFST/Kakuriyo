# Kakuriyo vault v1 gates

One command runs every gate:

```bash
nix-shell --run "npm run gate"
```

Gates run in order; first failure stops the set (non-zero exit).

| Gate | Script | Rule |
|------|--------|------|
| check | `tools/gates/gate-check.sh` | `native check --strict` — markup bindings, app.zon, TS subset. Patches `zig-out/model-contract.zon` with `viewUnbound` from the frontend contract (compiled sidecar gap). |
| ts-core seam | `tools/gates/gate-ts.sh` | `zig build test -Dplatform=null` — effects channel + binding oracles (ping/echo/unknown + full vault lifecycle/rewrap/atomic/locked-save via `host_roundtrip_tests.zig`; node core harness 9 oracles). |
| vault oracles | `tools/gates/gate-vault.sh` | `zig build test-vault` — envelope + host + domain (KDAT v3, senhas gate, ingest) + preview og:image. |
| zig fmt | `tools/gates/gate-zig.sh` | `zig fmt --check` on `src`, `build`, `build.zig`. |
| smoke | `tools/smoke/run.sh` | vault unit tests + app tests + `kakuriyo-smoke` driver + `tools/smoke/ui-redesign.sh` (ingest/select cache/senhas/lock). |
| mutation | `tools/gates/gate-mutate.sh` | M1–M8 mutants; each must kill exactly one oracle (`tools/gates/mutate.sh`). |

## Mutation dispositions (M1–M8)

| Mutant | Kills |
|--------|-------|
| M1 wrong_aad | golden file vector |
| M2 constant_nonce | save rotates payload nonce |
| M3 no_zero_on_lock | lock zeroes secrets |
| M4 ignore_auth_error | tampered ciphertext → corrupt (not wrong_password) |
| M5 reuse_dek | DEK independent of KEK |
| M6 no_atomic | atomic save held-generation oracle |
| M7 no_rewrap | change password region identity |
| M8 no_version_bind | golden file vector |

No survivors as of 2026-08-09.

## Fast loops

```bash
nix-shell --run "zig build test-vault"          # vault only (~28s)
nix-shell --run "zig build test -Dplatform=null" # app seam (~22s)
nix-shell --run "bash tools/smoke/run.sh"        # smoke without mutation (~90s)
```
