# Kakuriyo UI/UX redesign

Date: 2026-08-16  
Status: draft for user review  
Stack: Native SDK 0.8.x, Zig AppController, vault v1 envelope (Argon2id + XChaCha20-Poly1305)

## Goal

Replace the current session UI with a clear two-area vault: **Links** (bulk URL ingest + fast preview) and **Passwords** (separate gate). Master password creates/unlocks the vault; the Passwords tab has its own gate password with stronger rules.

## Non-goals (this ship)

- Vim / Classic keyboard profiles and IDE activity-bar chrome from the older full-app plan
- Export / import UI
- Sync, cloud, telemetry
- Full-resolution media download; only capped preview thumbnails
- Separate vault files for links vs passwords

## Decisions (locked)

| Topic | Choice |
|-------|--------|
| Architecture | Zig `AppController` + `app_view`; `core.ts` number slots only |
| Master password | Create with confirm; min 8 chars; unlock with password only |
| Passwords gate | Second password ≠ master; created on first visit to Senhas after master unlock |
| Passwords gate rules | Must include uppercase, lowercase, digit, special character |
| Bulk links | Auto-group into Collections by URL host |
| Preview on select | Paint from in-memory vault cache in &lt;1s; no network on select |
| Thumbnail storage | JPEG (or equivalent) bytes inside encrypted Entry, max 128 KiB |
| Preview network | Background fetch / Refresh with ~800ms hard budget; failure keeps placeholder / prior cache |

## Architecture

One encrypted vault file. Plaintext domain blob (`KDAT`) holds collections, link entries, secrets list, and the passwords-gate verifier (salt + hash). The master DEK encrypts the whole blob; locking clears DEK and any in-session passwords-gate unlock flag.

```
┌─────────────────────────────────────────┐
│ app_view (GTK via Zig)                  │
│  Auth | Links shell | Senhas shell      │
└──────────────┬──────────────────────────┘
               │ msgs / slots
┌──────────────▼──────────────────────────┐
│ AppController                           │
│  phase, activity, selection, buffers    │
│  intercepts unlock / ingest / CRUD      │
└──────────────┬──────────────────────────┘
               │
     ┌─────────┴─────────┐
     ▼                   ▼
 vault_host / Session   domain.Store
 (envelope I/O)         (KDAT encode/decode)
     │
     ▼
 preview (HTML parse + image fetch/resize)
```

TS compiled lane stays identity/`Cmd`-free for vault mutations (existing lane limit).

## Screens and flows

### Auth

1. **Fresh** — no vault file: master password + confirm (min 8). Mismatch or too short → error, stay on form.
2. **Locked** — vault exists: single password field + Unlock. Wrong password → fail closed.
3. **Unlocked** — top bar: **Links | Senhas** + Lock. Lock saves if dirty, drops DEK, drops Senhas gate session.

### Links

Layout: tree (host collections → entries) | editor (title, URL, notes) | preview (thumbnail, title, description).

**Bulk ingest:** multi-line paste box. Parse `http(s)://` URLs. For each URL:

1. Extract host (lowercase, strip `www.` optional — pick one rule and keep it).
2. Ensure Collection named by host under root (create if missing).
3. Ensure Entry under that collection; duplicate URL → skip or refresh metadata only (no second entry).
4. Queue preview fetch per new/updated entry (non-blocking).

**Preview:**

- Select Entry: render cached `preview_title`, `preview_description`, `preview_image` immediately.
- Missing image → placeholder glyph/panel; never block select on network.
- Refresh / post-ingest fetch: GET URL origin only, no Referer, Kakuriyo UA, body cap, 800ms budget. Parse OG/Twitter/HTML for title/description/`og:image` (or equivalent). Fetch image, resize/re-encode to ≤128 KiB JPEG, store on Entry, persist vault when save path runs.

### Senhas

1. First visit with gate unset → create gate password + confirm with four character classes; store verifier in domain.
2. Later visits while gate locked → unlock field only.
3. Gate unlocked → list + CRUD for secrets: label, username, password (masked + reveal), notes.
4. Switching to Links within the same unlocked master session keeps Senhas gate unlocked. Master Lock or process exit clears it.

Stored secret passwords are not required to pass the four-class rule; that rule applies only to the Senhas **gate** password.

## Domain model changes

Bump `KDAT` version as needed (compatible migration from current v2 entries).

- **Entry:** existing fields + `preview_image: []u8` (owned, may be empty).
- **SecretsGate:** `unset` | `{ salt, hash_params, hash }` using Argon2id (same family as vault KDF; parameters documented in code).
- **Secret:** `id`, `label`, `username`, `password`, `notes`, timestamps.
- **Store:** nodes (collections/entries) + secrets list + gate state.

Host grouping uses the Entry `url` host; Collection `name` = host string.

## Error handling

| Case | Behavior |
|------|----------|
| Wrong master / wrong gate | Clear error text; no plaintext leak; stay locked |
| Weak Senhas gate on create | Block submit; list missing classes |
| Confirm mismatch | Block submit |
| Corrupt vault / unsupported version | Locked screen message; no crash |
| Preview timeout / HTTP error | Keep prior cache or empty placeholder |
| Image too large / decode fail | Skip image; keep text meta if any |

## Testing / prove

Oracles must exit non-zero on failure:

1. Master create + unlock + lock roundtrip.
2. Senhas gate create rejects weak passwords; accepts strong; unlock works; wrong gate fails.
3. Bulk paste → one Collection per distinct host; URL dedupe.
4. Select path paints preview from cache with no network (unit/simulation timing budget).
5. Fetch respects budget; owned strings (no dangling slices); image capped ≤128 KiB.
6. Master lock clears Senhas gate session flag.
7. Smoke / headless e2e covering auth → ingest → select preview → Senhas gate → CRUD secret.
8. Extend `tools/gates/` / ledger so `npm run gate` covers the new surfaces.

## Files likely touched

- `src/app_runner/app_controller.zig`, `app_view.zig`, `app_dispatch.zig`, related keyboard/input bridges
- `src/vault/domain.zig`, `preview.zig`, `vault.zig` / host, tests
- `src/core.ts`, `src/app.native` (slots / placeholder alignment)
- `tools/gates/`, `.scratch/kakuriyo/prove/ledger.md`, `GATES.md` as needed

## Success criteria

- User can create master (confirm) and later unlock with master only.
- User can paste many URLs; app groups by host and shows thumbnail preview from cache in under one second on select.
- User can open Senhas, set a strong gate password on first use, unlock later, and store secrets.
- Gates and smoke/e2e prove the flows above before ship.
