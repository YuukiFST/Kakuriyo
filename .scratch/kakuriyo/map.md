# Kakuriyo — wayfinder map

**Live map:** https://github.com/YuukiFST/Kakuriyo/issues/22  
Label: `wayfinder:map`  
Local `.scratch/kakuriyo/issues/` = archive only. Tracker: `docs/issue-tracker.md`.

## Destination

A handoff **spec** for **Kakuriyo**: standalone dark desktop vault (Win11 + NixOS), Master Password + encrypted Vault, nested Collections, flexible Entries (optional URL → Preview), keyboard-first, export/import backup file, zero telemetry/auth/cloud — ready for another session to build.

## Notes

- Canonical tracker: GitHub Issues (`docs/issue-tracker.md`). `.scratch/kakuriyo/issues/` is archive only.
- Domain language: English product UI/terms; see `CONTEXT.md` at repo root.
- Skills every session: grilling, domain-modeling, research, prototype.
- Stack preference: **gpui** (confirmed go-with-caveats).
- Privacy bar: local encrypted at rest + auto-lock; not “hide from screen share only”.
- Cost: $0 ops (no paid backend). Offline-first; Preview may fetch when online and cache locally.
- Plan, don’t ship the map’s destination app inside this effort unless Notes later override.
- Keyboard: Vim Motion ON by default, user-toggleable (Settings + command palette); Classic fallback when OFF.

## Decisions so far

- [gpui viability for Kakuriyo](https://github.com/YuukiFST/Kakuriyo/issues/1) — go-with-caveats: GPUI + gpui-component fit; pin git, budget NixOS packaging / pre-1.0 churn
- [Encrypted Vault at rest](https://github.com/YuukiFST/Kakuriyo/issues/3) — Argon2id KEK + random DEK + XChaCha20-Poly1305; secrecy/zeroize; backup = vault copy or age
- [Link Preview fetch and local cache](https://github.com/YuukiFST/Kakuriyo/issues/2) — reqwest (no Referer, short UA) + webpage parse-only; OG→Twitter→HTML; Vault-backed offline cache; no third-party unfurl
- [Entry flexible fields](https://github.com/YuukiFST/Kakuriyo/issues/4) — one flexible type; required Title; optional URL (≤1, soft check) + plain Body; no tags/Phone field; read-only created/updated; Title-only OK
- [Nested Collection semantics](https://github.com/YuukiFST/Kakuriyo/issues/5) — Entry lives in exactly one place (Collection or root); folders not tags; no depth cap; name unique per parent; delete evacuates children to parent, never cascades; empty Collections persist; keyboard needs tree traversal + inline create/rename/delete
- [Main layout prototype](https://github.com/YuukiFST/Kakuriyo/issues/6) — v1 = IDE B (activity + tree with Entries + editor|Preview), TRUE BLACK; secrets = structured User/Password rows over Body + `•••` tree badge; density deferred to keyboard ticket
- [Keyboard-first navigation](https://github.com/YuukiFST/Kakuriyo/issues/7) — Vim Motion ON default (hjkl, gx, a/A, x/p, Ctrl-w, / filter); Classic OFF via Settings+palette; Preview on select; Delete modal y/Esc; clipboard SO ≠ tree move; compact ring inset
- [Unlock and Auto-lock policy](https://github.com/YuukiFST/Kakuriyo/issues/17) — create min 8 + confirm; Unlock-only UI; idle 5m default (1/5/15/30/Never); quit=lock; minimize OFF default; auto-save then lock; Unlock lockout 5 fails/5m; change PW = current+new+confirm rewrap

## Not yet specified

- Global hotkey / "panic hide" while screen-sharing
- In-Vault search / filter UX beyond v1 Explorer `/` filter (SR view depth; ranking; scope)
- Clipboard / "paste URL → new Entry" capture flow (and Copy-password clear timing)
- Tray icon vs window-only (v1 close = quit until this lands)
- Entry field size limits (Title/Body max length)
- Entry delete undo/trash (confirm keyboard locked on #7; soft-delete / undo still open)

## Out of scope

- Cloud account, remote sync, paid hosting
- Mobile apps
- Browser extension
- Telemetry / analytics / crash phone-home
- AI features
- Becoming a full 1Password competitor (passwords may live as Entry text; not a browser autofill suite)
