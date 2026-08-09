# Kakuriyo — wayfinder map

**Live map:** https://github.com/YuukiFST/Kakuriyo/issues/22  
Label: `wayfinder:map`  
Local `.scratch/kakuriyo/issues/` = archive only. Tracker: `docs/issue-tracker.md`.

## Destination

A handoff **spec** for **Kakuriyo**: standalone dark desktop vault (Win11 + NixOS), Master Password + encrypted Vault, nested Collections, flexible Entries (optional URL → Preview), keyboard-first, export/import backup file, zero telemetry/auth/cloud — ready for another session to build.

**Delivered:** [`.scratch/kakuriyo/spec.md`](spec.md)

## Notes

- Canonical tracker: GitHub Issues (`docs/issue-tracker.md`). `.scratch/kakuriyo/issues/` is archive only.
- Domain language: English product UI/terms; see `CONTEXT.md` at repo root.
- Skills every session: grilling, domain-modeling, research, prototype.
- Stack preference: **Native SDK** (`vercel-labs/native`) + **TypeScript** core (supersedes GPUI; see [Adopt Native SDK as Kakuriyo stack](https://github.com/YuukiFST/Kakuriyo/issues/26)).
- Crypto: algorithms from #3 stay; Zig std under TS core via `Cmd.request`/`bindHostCalls` — [Native SDK Zig crypto + NixOS smoke](https://github.com/YuukiFST/Kakuriyo/issues/27) **go-with-caveats** (NixOS DIY wrap; eject/`--full` for host bindings).
- Privacy bar: local encrypted at rest + auto-lock; not "hide from screen share only".
- Cost: $0 ops (no paid backend). Offline-first; Preview may fetch when online and cache locally.
- Plan, don't ship the map's destination app inside this effort unless Notes later override.
- Keyboard: Vim Motion ON by default, user-toggleable (Settings + command palette); Classic fallback when OFF.

## Tickets

- [x] #1 gpui viability for Kakuriyo *(superseded by #26)*
- [x] #2 Link Preview fetch and local cache *(HTTP client language assumption superseded — see fog)*
- [x] #3 Encrypted Vault at rest *(algorithms keep; Zig reimplementation via #27)*
- [x] #4 Entry flexible fields
- [x] #5 Nested Collection semantics
- [x] #6 Main layout prototype
- [x] #7 Keyboard-first navigation
- [x] #17 Unlock and Auto-lock policy
- [x] #24 Native SDK vs GPUI (agent DX) *(superseded by #26)*
- [x] #26 Adopt Native SDK as Kakuriyo stack
- [x] #27 Native SDK Zig crypto + NixOS smoke
- [x] #8 Export / Import backup UX
- [x] #9 Handoff spec assembly → [spec.md](spec.md)

## Decisions so far

- [gpui viability for Kakuriyo](https://github.com/YuukiFST/Kakuriyo/issues/1) — **superseded**: was go-with-caveats GPUI; stack now Native via #26
- [Encrypted Vault at rest](https://github.com/YuukiFST/Kakuriyo/issues/3) — Argon2id KEK + random DEK + XChaCha20-Poly1305; secrecy/zeroize; backup = vault copy or age *(language: Zig under Native — #27)*
- [Link Preview fetch and local cache](https://github.com/YuukiFST/Kakuriyo/issues/2) — OG→Twitter→HTML; Vault-backed offline cache; no third-party unfurl *(HTTP client was reqwest — rewrite under Native deferred to fog)*
- [Entry flexible fields](https://github.com/YuukiFST/Kakuriyo/issues/4) — one flexible type; required Title; optional URL (≤1, soft check) + plain Body; no tags/Phone field; read-only created/updated; Title-only OK
- [Nested Collection semantics](https://github.com/YuukiFST/Kakuriyo/issues/5) — Entry lives in exactly one place (Collection or root); folders not tags; no depth cap; name unique per parent; delete evacuates children to parent, never cascades; empty Collections persist; keyboard needs tree traversal + inline create/rename/delete
- [Main layout prototype](https://github.com/YuukiFST/Kakuriyo/issues/6) — v1 = IDE B (activity + tree with Entries + editor|Preview), TRUE BLACK; secrets = structured User/Password rows over Body + `•••` tree badge; density deferred to keyboard ticket
- [Keyboard-first navigation](https://github.com/YuukiFST/Kakuriyo/issues/7) — Vim Motion ON default (hjkl, gx, a/A, x/p, Ctrl-w, / filter); Classic OFF via Settings+palette; Preview on select; Delete modal y/Esc; clipboard SO ≠ tree move; compact ring inset
- [Unlock and Auto-lock policy](https://github.com/YuukiFST/Kakuriyo/issues/17) — create min 8 + confirm; Unlock-only UI; idle 5m default (1/5/15/30/Never); quit=lock; minimize OFF default; auto-save then lock; Unlock lockout 5 fails/5m; change PW = current+new+confirm rewrap
- [Native SDK vs GPUI (agent DX)](https://github.com/YuukiFST/Kakuriyo/issues/24) — **superseded**: was keep GPUI; reversed by #26
- [Adopt Native SDK as Kakuriyo stack](https://github.com/YuukiFST/Kakuriyo/issues/26) — Native SDK + TypeScript core; crypto Zig under TS; Preview HTTP fog; product gist kept
- [Native SDK Zig crypto + NixOS smoke](https://github.com/YuukiFST/Kakuriyo/issues/27) — go-with-caveats: Zig std Argon2id+XChaCha+secureZero; TS→Zig via Cmd.host; NixOS DIY GTK4/Zig wrap; Win early
- [Export / Import backup UX](https://github.com/YuukiFST/Kakuriyo/issues/8) — `.kakuriyo` Vault copy (no age v1); Import asks Replace|Merge + file Master Password; Replace auto `.bak`; Merge by UUID with per-conflict Keep local|imported|both; clear errors, no partial write; unlocked after success; Settings+palette
- [Handoff spec assembly](https://github.com/YuukiFST/Kakuriyo/issues/9) — destination delivered at `.scratch/kakuriyo/spec.md` (Native+TS+Zig crypto; product locks from closed tickets; fog called out)

## Not yet specified

Post-handoff backlog (not required to start building from the spec):

- Preview HTTP/unfurl client under Native (replaces #2 reqwest assumption)
- Native re-prototype of IDE layout / Vim Motion surface (gist from #6/#7 stays)
- Global hotkey / "panic hide" while screen-sharing
- In-Vault search / filter UX beyond v1 Explorer `/` filter (SR view depth; ranking; scope)
- Clipboard / "paste URL → new Entry" capture flow (and Copy-password clear timing)
- Tray icon vs window-only (v1 close = quit until this lands; Linux tray UnsupportedService on Native today)
- Entry field size limits (Title/Body max length)
- Entry delete undo/trash (confirm keyboard locked on #7; soft-delete / undo still open)

## Out of scope

- `.age` passphrase Export (deferred; v1 = Vault file copy only)
- Cloud account, remote sync, paid hosting
- Mobile apps
- Browser extension
- Telemetry / analytics / crash phone-home
- AI features
- Becoming a full 1Password competitor (passwords may live as Entry text; not a browser autofill suite)
