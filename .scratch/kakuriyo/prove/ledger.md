# Kakuriyo vault v1 — prove ledger

## Surface table

| Surface | Tier | Layers | Coverage | Mutation | Gates |
|---------|------|--------|----------|----------|-------|
| vault envelope (`vault.zig`) | T2 | unit + property (40 payloads) | create/unlock/save/lock/changePassword, wrong password, tamper, version/magic, atomicity (held handle), golden vector, DEK≠KEK | 8/8 killed | test-vault, mutate |
| host dispatch (`vault_host.zig`) | T2 | framed protocol tests | lifecycle, bad_request, error codes, session hygiene | (covered by vault gate) | test-vault |
| effects seam (`host_roundtrip_tests`) | T1 | binding oracles | ping sendFn, requestFn echo, unknown reject | n/a | gate-ts |
| smoke driver (`smoke.zig`) | T2 | end-to-end file | full password lifecycle + rewrap region check | n/a | smoke |
| TS core lane | documented constraint | — | frame-arena UAF; no Cmd in core | n/a | gate-check (viewUnbound patch) |
| CI (`npm run gate`) | T1 | ubuntu gate suite | same script as local nix-shell | n/a | `.github/workflows/ci.yml` |

## Skipped / deferred

- **Dir.iterate leftover oracle**: Threaded testing Io hits `errnoBug(BADF)` on fresh tmp dirs. Replaced by held-file-generation oracle (stronger for M6).
- **Compiled-sidecar viewUnbound**: scriptc co-emit omits unbound lists; `patch-model-contract-unbound.sh` merges frontend contract before `native check --strict`.
- **Full-loop TS dispatch tests** (Task 5 step 1): blocked by TS lane constraint; binding-level proof stands.
- **UI / real-window path**: out of scope for this goal.

## Adversarial pass (what was hunted)

- Torn saves → held handle + fresh-unlock generation oracle; M6 no_atomic
- Wrong password leaving session unlocked → `unlock()` locks first; smoke PASS wrong-password
- Nonce reuse → rotation oracle; M2
- Key mixups (DEK=KEK) → independence oracle; M5; golden vector pins AAD
- Lock-path secrets → zeroing oracle; M3
- Password rewrap vs re-encrypt → region identity oracle; M7
- Tamper classification → corrupt vs wrong_password; M4

## Riskiest unproven thing

Password buffers in TS arena memory after routed dispatches (threat model: host-owned vault path only; TS core does not carry secrets on this SDK version).
