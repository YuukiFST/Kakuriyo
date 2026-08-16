# Kakuriyo — prove ledger (full app)

## Surface table

| Surface | Tier | Layers | Coverage | Mutation | Gates |
|---------|------|--------|----------|----------|-------|
| vault envelope (`vault.zig`) | T2 | unit + property (40 payloads) | create/unlock/save/lock/changePassword, decryptPayloadFile, wrong password, tamper, version/magic, atomicity, golden vector | 8/8 killed | test-vault, mutate |
| host dispatch (`vault_host.zig`) | T2 | framed protocol tests | lifecycle, bad_request, error codes, session hygiene | (vault gate) | test-vault |
| domain model (`domain.zig`) | T2 | unit oracles | CRUD, KDAT v3 preview_image, secrets gate + Secret list, bulk ingest by host | n/a | test-vault |
| preview parser (`preview.zig`) | T1 | unit oracles | OG/Twitter/title/`og:image` parse; 128KiB image cap; owned fetch strings; 800ms budget timeout | n/a | test-vault |
| AppController (`app_controller.zig`) | T2 | unit oracles | lifecycle, Links ingest, cache-first select (no fetch), Senhas gate+CRUD, lock clears gate session | n/a | gate-ts, ui-redesign smoke |
| keyboard (`app_keyboard.zig`) | T1 | unit smoke | vim j/k, modal guards | n/a | gate-ts |
| effects seam (`host_roundtrip_tests`) | T1 | binding oracles | vault lifecycle through effects channel | n/a | gate-ts |
| TS core slots (`core.ts`) | T1 | node harness | identity update, subscriptions idle timer | n/a | gate-ts, gate-check |
| smoke driver (`smoke.zig`) | T2 | end-to-end file | full password lifecycle + rewrap | n/a | smoke |
| packaging (`gate-package.sh`) | T1 | package smoke | linux artifact + windows scaffold note | n/a | package smoke |
| CI (`npm run gate`) | T1 | full suite | same as local nix-shell | n/a | ci.yml |

## Skipped / deferred

- **Real-window UI automation**: native-sdk headless path only; layout verified by Zig view compile + manual.
- **Native file picker for export/import**: v1 stages `vault.import` / writes `vault.export` beside the vault path (documented in import modal). Native `openFile`/`saveFile` dialogs deferred — requires async effects wiring from the Zig controller.
- **Win11 packaging validation**: linux gate builds `zig-out/package/kakuriyo-linux`; windows scaffold documented for manual Win11 run.

## Riskiest unproven thing

Link preview HTTP fetch is ownership-tested + 800ms budget-tested (blackhole), wired on save/refresh, but not exercised against live hosts in CI (network-free gates). Manual verify with a real URL recommended.
