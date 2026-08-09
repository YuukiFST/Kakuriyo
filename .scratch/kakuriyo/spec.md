# Kakuriyo — handoff spec (v1)

**Done when:** another session can scaffold and implement Kakuriyo from this file + linked research/tickets **without re-opening product scope**. Fog and Out of scope below are deliberate non-decisions / non-goals — do not invent answers for them in v1.

**Map:** [Kakuriyo — wayfinder map](https://github.com/YuukiFST/Kakuriyo/issues/22)  
**Glossary:** [`CONTEXT.md`](../../CONTEXT.md) (single source of truth for product terms)  
**Tracker:** [`docs/issue-tracker.md`](../../docs/issue-tracker.md)

---

## Product gist

**Kakuriyo** is a standalone dark desktop **Vault** for private **Entries** (links and other text), organized in nested **Collections**. Offline-first, Master Password unlock, encrypted at rest, keyboard-first, zero telemetry / auth / cloud. Targets **Windows 11** and **Linux/NixOS**.

Privacy bar = local encryption + Auto-lock — not “hide from screen share only.”

---

## Stack (locked)

| Layer | Choice | Source |
| --- | --- | --- |
| UI / runtime | [Native SDK](https://github.com/vercel-labs/native) (`vercel-labs/native`) | [#26](https://github.com/YuukiFST/Kakuriyo/issues/26) |
| App core | **TypeScript** + `.native` markup | #26 |
| Crypto | **Zig** `std.crypto` behind host bindings (`Cmd.request` / `bindHostCalls`); algorithms from #3 | [#27](https://github.com/YuukiFST/Kakuriyo/issues/27) |
| Superseded | GPUI / Rust UI stack (#1, #24) | superseded by #26 |

**Build posture:** expect `native eject` / `--full` to own Zig host wiring. Prefer Fallback A from research (TS core + Zig vault service). Do not ship spawn-sidecar crypto or pure-TS Argon2.

**Detail:** [`.scratch/kakuriyo/research/12-native-zig-crypto-nixos.md`](research/12-native-zig-crypto-nixos.md)  
**Prior Native vs GPUI (historical):** [research/11-native-sdk-vs-gpui.md](research/11-native-sdk-vs-gpui.md)

---

## Crypto at rest (locked algorithms)

Envelope encryption (language is Zig; design from #3):

1. CSPRNG **DEK** (32 bytes) — never derived from the password alone.
2. CSPRNG **salt** + stored Argon2id params → **KEK** = Argon2id(Master Password, salt, params).
3. Wrap DEK under KEK with **XChaCha20-Poly1305**.
4. Encrypt vault payload under DEK with **XChaCha20-Poly1305**.
5. Persist versioned header + ciphertext; bind version (and chosen AAD) into AEAD.
6. Atomic save: temp → fsync → rename.
7. Lock / Auto-lock: drop unlocked session; `secureZero` KEK/DEK/password buffers (best-effort; not anti-DMA).

**Baseline KDF params:** OWASP / `Params.owasp_2id` — `t=2`, `m=19*1024`, `p=1`. Persist params beside salt; may raise for desktop UX.

**Password change:** new salt/params → new KEK → re-wrap same DEK; payload untouched.

**Detail:** [research/03-encrypted-vault-at-rest.md](research/03-encrypted-vault-at-rest.md) (Rust crate names are historical; Zig mapping is in research/12).

---

## Domain model (locked)

Read [`CONTEXT.md`](../../CONTEXT.md). Do not invent alternate product types.

### Entry ([#4](https://github.com/YuukiFST/Kakuriyo/issues/4))

One flexible type:

| Field | Rule |
| --- | --- |
| Title | Required; reject blank/whitespace |
| URL | Optional; ≤1; soft validation; Preview only when present |
| Body | Optional plain text; phones/secrets/extra links live here |
| Tags | None |
| created / updated | Stored; read-only in UI |

Title-only Entries allowed.

### Collection ([#5](https://github.com/YuukiFST/Kakuriyo/issues/5))

- Folders, not tags. Entry lives in **exactly one** place (Collection or Vault root).
- Root holds Collections and loose Entries.
- Name unique **per parent**; no depth cap.
- Move Collection = whole subtree; cycles forbidden.
- Delete Collection **evacuates** children to parent — never cascade-delete.
- Empty Collections persist.

### Secrets presentation ([#6](https://github.com/YuukiFST/Kakuriyo/issues/6))

Still one Entry type. Editor prefers structured User + Password (Show/Hide + Copy) **over Body**; plain Body toggle remains. Explorer may show `•••` badge as a visual hint only.

---

## UX chrome (locked gist)

### Layout ([#6](https://github.com/YuukiFST/Kakuriyo/issues/6))

Variant **B — IDE**: activity bar (EX / SR / LK) + Explorer tree (Collections + Entry leaves) + main split **editor | Preview** (~50% Preview). TRUE BLACK (`#000` chrome). Nesting = indent + twisty.

**Prototype (visual reference only; rebuild under Native):** [prototypes/06-main-layout.html](prototypes/06-main-layout.html) (`?variant=B`).

Density: tree row ~22–24px; focus inset 1px `#ffffff`; selection `#1c1c1c` ([#7](https://github.com/YuukiFST/Kakuriyo/issues/7)).

### Keyboard ([#7](https://github.com/YuukiFST/Kakuriyo/issues/7))

**Vim Motion ON by default** (toggle via Settings + command palette **“Toggle Vim Motion”**; no mid-type hotkey).

| Action | Vim ON | Classic OFF |
| --- | --- | --- |
| Move / nest | `j`/`k`, `h`/`l` (arrows alias) | arrows |
| Tree ↔ Editor | `Ctrl-w` h/l/w; `Esc` → tree | `Enter` / `Esc` |
| Open URL | `gx` | `Ctrl-Enter` |
| New Entry / Collection | `a` / `A` | command/menu |
| Rename / Delete | `r`/`F2`; `Delete` → modal `y`/`Esc` | `F2` / `Delete` |
| Cut / Paste node | `x` / `p` | Cut node / Paste node commands |
| Filter | `/` or `Ctrl-f` | same |
| Lock | `Ctrl-Shift-L` | same |
| Activity | `1` EX, `2` SR | same |

**Invariants:** Preview follows selection immediately (not a first-level focus target). Editor focus kills tree letter-motions. OS clipboard (`Ctrl-C`/`X`/`V`) ≠ tree move. No counts/`gg`/`G`/Visual/operators in v1.

### Unlock / Auto-lock ([#17](https://github.com/YuukiFST/Kakuriyo/issues/17))

- First-run: Master Password + confirm; **min length 8**; Vault in default OS app-data path (no folder picker).
- Unlock UI: password + Unlock only (no biometrics/hint/wipe). Show/hide toggle on create/Unlock/change.
- Failures: **5** wrong Unlock → **5 min** lockout on Unlock screen; no wipe. Change-password current failures = immediate error only.
- Auto-lock idle: no in-app input; default **5 min**; presets **1 / 5 / 15 / 30 / Never**.
- Quit = close window = lock (no tray in v1). Minimize-lock **OFF** by default.
- Before lock: auto-save dirty Entry, then lock.
- Change password: current + new + confirm → rewrap DEK.
- Post-Unlock: restore last Collection/Entry focus.

### Export / Import ([#8](https://github.com/YuukiFST/Kakuriyo/issues/8))

- **Export:** copy on-disk Vault ciphertext → `.kakuriyo` (versioned header); includes Preview cache when present. Settings + palette; Vault must be unlocked. No `.age` in v1.
- **Import:** prompt for **file’s** Master Password; ask **Replace | Merge**. Distinct errors (wrong password / corrupt / unsupported version); **no partial write**. Failed attempts share Unlock lockout when applicable. Success leaves Vault **unlocked**.
- **Replace:** confirm → auto `.bak` of current → swap.
- **Merge:** match by stable **UUID**; conflicts (UUID or Collection name under same parent) → Keep local | Keep imported | Keep both (rename imported). Esc cancels entire Merge (nothing written). No silent last-write-wins.

---

## Preview (partially locked)

**Locked product rules** ([#2](https://github.com/YuukiFST/Kakuriyo/issues/2)):

- First-party fetch of Entry URL; parse OG → Twitter → HTML title/description; cache Preview (+ optional image) **inside encrypted Vault**; no third-party unfurl.
- Privacy: no `Referer`; short `Kakuriyo/x.y` UA; no cookies; no telemetry.
- Offline: show cached Preview when present.

**Open for implementers (fog):** HTTP client under Native/TS (Rust `reqwest` assumption superseded). Reuse parse-order and privacy rules; pick the Native-era HTTP stack when building.

**Detail:** [research/02-link-preview-fetch-cache.md](research/02-link-preview-fetch-cache.md)

---

## Packaging targets

| Target | Expectation |
| --- | --- |
| NixOS / Linux | DIY wrap: Zig 0.16 + Node + GTK4; `native package --target linux`; wrap for Nix store libs (no upstream flake) |
| Win11 | Real host; early packaging directory + optional file-type script; validate on Windows before release claims |

See research/12 checklist.

---

## Out of scope (do not build in this effort’s v1)

From the map:

- Cloud account, remote sync, paid hosting
- Mobile apps, browser extension
- Telemetry / analytics / crash phone-home
- AI features
- Full 1Password competitor / browser autofill suite
- `.age` passphrase Export (deferred)

---

## Fog (not decided — do not invent for v1 handoff)

Leave as later tickets / settings stubs only if unavoidable:

- Preview HTTP/unfurl client under Native
- Native re-prototype of IDE layout / Vim Motion surface (gist above stays)
- Global hotkey / panic hide while screen-sharing
- In-Vault search beyond Explorer `/` filter
- Clipboard “paste URL → new Entry” + copy-password clear timing
- Tray icon (Linux tray UnsupportedService on Native today; v1 close = quit)
- Entry Title/Body max length
- Entry delete undo / trash (confirm modal locked; soft-delete open)

---

## Suggested build order

Completion criterion for each step: the named capability works under Unlock with encrypted persistence (or the step’s stated smoke).

1. Scaffold Native TS app; eject; wire empty `vault.zig` host service (`Cmd.request` round-trip).
2. Vault create / Unlock / Lock / password-change / atomic save (envelope from this spec).
3. Domain model: Collections + Entries CRUD matching #4/#5; UUID stability for Merge later.
4. Unlock / Auto-lock / idle / lockout UI (#17).
5. Explorer + editor chrome gist (#6); TRUE BLACK; structured secret rows.
6. Keyboard profiles (#7).
7. Preview pipeline (privacy rules #2; Native HTTP chosen here).
8. Export / Import Replace|Merge (#8).
9. NixOS wrap smoke + Win11 package smoke (research/12).

---

## Ticket / asset index

| Topic | Issue | Asset |
| --- | --- | --- |
| Stack Native + TS | [#26](https://github.com/YuukiFST/Kakuriyo/issues/26) | — |
| Zig crypto + NixOS | [#27](https://github.com/YuukiFST/Kakuriyo/issues/27) | [research/12](research/12-native-zig-crypto-nixos.md) |
| Crypto algorithms | [#3](https://github.com/YuukiFST/Kakuriyo/issues/3) | [research/03](research/03-encrypted-vault-at-rest.md) |
| Preview rules | [#2](https://github.com/YuukiFST/Kakuriyo/issues/2) | [research/02](research/02-link-preview-fetch-cache.md) |
| Entry fields | [#4](https://github.com/YuukiFST/Kakuriyo/issues/4) | `CONTEXT.md` |
| Collections | [#5](https://github.com/YuukiFST/Kakuriyo/issues/5) | `CONTEXT.md` |
| Layout | [#6](https://github.com/YuukiFST/Kakuriyo/issues/6) | [prototypes/06-main-layout.html](prototypes/06-main-layout.html) |
| Keyboard | [#7](https://github.com/YuukiFST/Kakuriyo/issues/7) | — |
| Unlock / Auto-lock | [#17](https://github.com/YuukiFST/Kakuriyo/issues/17) | — |
| Export / Import | [#8](https://github.com/YuukiFST/Kakuriyo/issues/8) | `CONTEXT.md` Export/Import/Replace/Merge |
| Superseded GPUI | [#1](https://github.com/YuukiFST/Kakuriyo/issues/1), [#24](https://github.com/YuukiFST/Kakuriyo/issues/24) | research/01, research/11 |
