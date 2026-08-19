# Kakuriyo Rust + GTK4 rewrite (handoff spec)

Date: 2026-08-18

**Done when:** another session can delete Zig / Native SDK and ship this surface **without reopening product or stack scope**.

**Map:** [Kakuriyo Rust+GTK rewrite — wayfinder map](https://github.com/YuukiFST/Kakuriyo/issues/42)  
**Glossary:** [`CONTEXT.md`](../../CONTEXT.md)  
**Product chrome freeze:** [`2026-08-16-kakuriyo-vault-shell.md`](./2026-08-16-kakuriyo-vault-shell.md) **minus Screen Block-out**.

This file is the destination of that map. It is **not** the implementation.

---

## Destination (product)

Linux/NixOS Kakuriyo: encrypted local Vault, nested Collections, bulk URL paste, folders left / entries center / title+URL+Body+Preview right, classic keyboard, Auto-lock, change Master Password, Export / Import Replace|Merge. **No** Screen Block-out. **No** Zig. **No** Native SDK. **No** GPUI.

---

## Stack (locked)

| Layer | Choice |
| --- | --- |
| UI | GTK4 via **Relm4 0.11** + **gtk4-rs 0.11**, no libadwaita |
| Language | Rust (one user process). nixpkgs `rustc` ≥ 1.93 (host nixpkgs: 1.95) |
| Crypto | RustCrypto: `argon2` + `chacha20poly1305` (`XChaCha20Poly1305`) + `zeroize` |
| Preview HTTP | **ureq**, cookies off, rustls + `RootCerts::PlatformVerifier` |
| OS | Linux only, NixOS first |
| Identity | `dev.yuukifst.kakuriyo` |
| Vault path | `$XDG_CONFIG_HOME/kakuriyo/vault.kakuriyo` else `~/.config/kakuriyo/vault.kakuriyo` |

**Forbidden:** Electron, Tauri/WebView, hosted PWA, sudo, Zig runtime, `@native-sdk/core` / `.native` / `core.ts` slots, GPUI / `gpui-component`, Cairo as GSK happy path, GPU compute for crypto/Preview.

---

## Perf (locked)

Process start → locked window **first paint < 800 ms**. Argon2id Unlock is **outside** that budget. Do not Unlock before first locked paint.

Gate: `Instant` at `main`; fail if first `GdkFrameClock::after-paint` on the locked window > 800 ms, or `gtk_native_get_renderer` is Cairo. `GTK_A11Y=none`. SLA on a NixOS Wayland box; GitHub Actions may skip or mutter-headless smoke only.

Leave `GSK_RENDERER` unset. iGPU-only machines: display GPU **is** the iGPU. See research 14.

---

## Vault v1 (locked)

Same bytes as Zig `src/vault/vault.zig`:

- Magic `KAKU`, version 1, AAD `kakuriyo/vault-v1`, 132-byte header, payload `ct\|\|tag`
- Argon2id v1.3 (`Version::V0x13`), params from file (`m` in KiB), default `{19456, 2, 1}`
- Random DEK; wrap DEK and payload with XChaCha20-Poly1305 (24-byte nonces)
- Password change: rewrap DEK only
- Atomic save: temp → fsync → rename
- Lock: `zeroize` DEK/payload/password buffers (best-effort, not anti-DMA)

Rust **must** pass `Payload { aad: b"kakuriyo/vault-v1" }` — a bare `&[u8]` encrypt will not open Zig files.

Oracle: cargo tests decrypt a Zig-written fixture; keep `zig build test-vault` until cutover.

Research: [13-vault-v1-rust-crypto.md](https://github.com/YuukiFST/Kakuriyo/blob/research/vault-v1-rust-crypto/.scratch/kakuriyo/research/13-vault-v1-rust-crypto.md)

---

## Workspace (locked)

Three crates:

1. `kakuriyo-vault` — envelope + domain store (no GTK)
2. `kakuriyo-preview` — HTML parse + ureq fetch (no GTK)
3. `kakuriyo` — Relm4 binary

Dev shell: `pkg-config`, `gtk4`, `glib`, `cairo`, `pango`, `gdk-pixbuf`, `graphene`, `wrapGAppsHook4`, `rustc`, `cargo`. Drop Zig/Node/`SCRIPTC_CC` from the happy path.

---

## UI / keyboard / paste (locked)

Copy 2026-08-16 vault-shell: folders left, entries center, editor+Preview right. TRUE BLACK via **GTK CSS** (`#000` chrome). No Vim Motion. No Links/Passwords activity bar.

Keyboard: arrows, Tab, Enter, Delete confirm, Ctrl+F, Ctrl+Shift+L, Ctrl+Enter open URL. Letter keys never move the tree.

Paste: many `http(s)` URLs; optional folder name; else selection or Inbox; batch stays together.

Preview: cache in Vault; no network on select; Refresh 800 ms; drop images > 128 KiB; UA `Kakuriyo/0.1`; no Referer; no cookies; 3 redirects max; ureq on a worker thread.

Auto-lock, lockout (5 fails / 5 min), change Master Password, Export/Import Replace|Merge: same product rules as vault-shell / `CONTEXT.md`.

---

## Gates (locked)

Replace `npm run gate` with:

1. `cargo test` (vault oracles + preview parse + UI-free logic)
2. `tools/gates/gate-first-paint.sh` (locked window, 800 ms, not Cairo)
3. `cargo fmt --check` / clippy as the Zig fmt stand-in

Mutation of vault envelope: port the spirit of `gate-mutate.sh` onto `kakuriyo-vault` when implementing.

CI: same scripts inside `nix-shell`. First-paint SLA **not** claimed on GPU-less runners.

Research: [15](https://github.com/YuukiFST/Kakuriyo/blob/research/relm4-gtk-rs-nixpkgs/.scratch/kakuriyo/research/15-relm4-gtk-rs-nixpkgs.md), [16](https://github.com/YuukiFST/Kakuriyo/blob/research/preview-http-rust/.scratch/kakuriyo/research/16-preview-http-rust.md), [17](https://github.com/YuukiFST/Kakuriyo/blob/research/gtk-first-paint-gate/.scratch/kakuriyo/research/17-gtk-first-paint-gate.md), [14](https://github.com/YuukiFST/Kakuriyo/blob/research/gtk4-gsk-igpu-nixos/.scratch/kakuriyo/research/14-gtk4-gsk-igpu-nixos.md)

---

## Suggested build order

1. `kakuriyo-vault` + Zig fixture round-trip
2. Unlock/create/lock Relm4 screens (first-paint gate green)
3. Domain CRUD + explorer chrome
4. Keyboard + paste
5. Preview ureq
6. Auto-lock / Export-Import
7. Delete Zig, Native SDK, `vendor/native-sdk`, Node editor surface

---

## Out of scope

- Screen Block-out / niri `block-out-from` as a product promise
- Windows
- Vim Motion, Discord bot, password-manager tab
- Electron / Tauri / PWA / GPUI
- Implementation in this document’s session (handoff only)
