# Kakuriyo UI/UX Redesign Implementation Plan

> **For agentic workers:** Use `executing-plans` (or equivalent) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Commits: use `git-safe-commit -m "..."` (never plain `git commit` — harness injects forbidden trailers). Author already configured.

**Goal:** Ship a working Kakuriyo desktop vault UI: master create/unlock, Links tab with bulk URL ingest grouped by host and &lt;1s cached thumbnail preview, Senhas tab with its own strong gate password and secret CRUD — proven by gates/smoke/e2e.

**Architecture:** Keep vault envelope in Zig. Rewrite session UI around `AppController` + `app_view.zig`. Domain blob (`KDAT`) gains `preview_image`, secrets gate verifier, and secrets list. `core.ts` stays number-slot identity only (no `Cmd.request` vault cycles).

**Tech Stack:** Native SDK 0.8.3, Zig (via `nix-shell`), GTK4, `npm run gate`, `git-safe-commit`.

**Spec:** `docs/specs/2026-08-16-kakuriyo-ui-redesign-design.md`

## Global Constraints

- Master password: min 8 chars + confirm on create; unlock with password only (no class rules).
- Senhas gate: uppercase + lowercase + digit + special; create on first visit to Senhas after master unlock.
- Bulk links: group Collections by host (lowercase host; strip leading `www.`).
- Select preview: paint from in-memory cache only; no network; target &lt;1s.
- Thumbnail: store image bytes on Entry when ≤128 KiB; skip image if larger/undecodable; keep title/description meta.
- Preview network budget: 800ms (`preview.fetch_budget_ms`).
- Non-goals: Vim profiles, IDE EX/SR/LK chrome, export/import UI, cloud/sync.
- All project commands: `cd /mnt/Others/Projects/PersonalProjects/Kakuriyo` then `nix-shell --run '...'`.
- Do not mark complete until `npm run gate` passes and dogfood flows work; then commit remaining work, open PR, merge to `main` (user already requested PR+merge in originating request).

## File map

| File | Responsibility |
|------|----------------|
| `src/vault/domain.zig` | KDAT encode/decode; Entry preview fields; secrets + gate; `ingestUrls` / host helpers |
| `src/vault/preview.zig` | HTML meta + `og:image` URL; fetch HTML/image with budget; owned buffers |
| `src/vault/tests.zig` | Domain/preview oracles (extend) |
| `src/app_runner/app_controller.zig` | Phases, Links/Senhas activity, ingest, gate session, secret CRUD, lock clears gate |
| `src/app_runner/app_view.zig` | Auth + Links shell + Senhas shell (rewrite) |
| `src/app_runner/app_dispatch.zig` | Wire new msgs to controller |
| `src/app_runner/app_keyboard.zig` | Minimal keys for new shell |
| `src/core.ts` | Slots/msgs alignment |
| `src/app.native` | Placeholder ok if Zig owns paint |
| `tools/gates/*`, `GATES.md`, `.scratch/kakuriyo/prove/ledger.md` | Oracles registration |
| `tools/smoke/` | Headless smoke covering new flows |

---

### Task 1: Domain — preview_image + KDAT v3 entry codec

**Files:**
- Modify: `src/vault/domain.zig`
- Test: `src/vault/domain.zig` (tests at bottom) and/or `src/vault/tests.zig`

**Interfaces:**
- Consumes: existing `Entry`, `Store.encode`/`decode`, `version` (=2 today)
- Produces: `version = 3`; `Entry.preview_image: []u8`; encode/decode roundtrip; v2 decode migrates empty image

- [ ] **Step 1: Write failing test** for entry with preview image roundtrip

```zig
test "entry preview_image roundtrip kdat v3" {
    const alloc = std.testing.allocator;
    var store = domain.Store.init(alloc);
    defer store.deinit();
    const id = try store.addEntry(domain.root_parent, "A", "https://ex.test/a", "", 1);
    try store.setPreview(id, "T", "D", "JPEGDATA");
    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);
    var decoded = try domain.Store.decode(alloc, encoded);
    defer decoded.deinit();
    const e = decoded.getEntry(id).?;
    try std.testing.expectEqualStrings("JPEGDATA", e.preview_image);
}
```

(Adapt helper names to match existing `addEntry` / update APIs — prefer extending existing methods rather than inventing parallel ones.)

- [ ] **Step 2: Run test — expect FAIL**

```bash
cd /mnt/Others/Projects/PersonalProjects/Kakuriyo
nix-shell --run "zig build test-vault"
```

Expected: compile or assertion failure around `preview_image` / version.

- [ ] **Step 3: Implement**

- Bump `pub const version: u32 = 3;` keep `version_v2 = 2` (and v1) for decode.
- Add `preview_image: []u8 = ""` on `Entry`; free in `deinit` / `deleteEntry`.
- Extend `writeEntry` / `readEntry`: after description, write `u32be length` + bytes.
- On decode v1/v2: set `preview_image` empty.
- Add `setPreview(self, id, title, description, image_bytes)` that owns duped slices.

- [ ] **Step 4: Re-run `zig build test-vault` — PASS** (existing tests still green)

- [ ] **Step 5: Commit**

```bash
git add src/vault/domain.zig src/vault/tests.zig
git-safe-commit -m "feat(domain): KDAT v3 entry preview_image codec"
```

---

### Task 2: Domain — secrets gate + Secret list

**Files:**
- Modify: `src/vault/domain.zig`
- Create (optional if file grows): `src/vault/secrets_gate.zig` for policy + verify helpers
- Test: domain tests

**Interfaces:**
- Consumes: Task 1 Store encode/decode
- Produces:
  - `pub const SecretsGate = union(enum) { unset, set: struct { salt: [16]u8, t_cost: u32, m_cost: u32, p_cost: u32, hash: [32]u8 } };`
  - `pub const Secret = struct { id: Uuid, label, username, password, notes: []const u8, created_ms, updated_ms: u64 };`
  - `Store.secrets_gate`, `Store.secrets: ArrayListUnmanaged(Secret)`
  - `pub fn passwordMeetsSenhasPolicy(pw: []const u8) bool` — needs upper, lower, digit, special (non-alphanumeric)
  - `pub fn setSecretsGateFromPassword(self: *Store, password: []const u8) !void`
  - `pub fn verifySecretsGate(self: *const Store, password: []const u8) bool`
  - CRUD: `addSecret`, `updateSecret`, `deleteSecret`, `getSecret`

Use lighter Argon2id params for gate than vault envelope if needed for UI snappiness in tests (`t=1,m=8*1024,p=1` ok for gate verifier inside already-encrypted blob).

Encode after nodes: `u8 gate_tag` (0 unset / 1 set) + fields; `u32be secret_count` + secrets. v1/v2 decode → gate unset, zero secrets.

- [ ] **Step 1: Failing tests**

```zig
test "senhas policy requires four classes" {
    try std.testing.expect(!domain.passwordMeetsSenhasPolicy("password"));
    try std.testing.expect(!domain.passwordMeetsSenhasPolicy("Password1"));
    try std.testing.expect(domain.passwordMeetsSenhasPolicy("Password1!"));
}

test "secrets gate set verify and secret roundtrip" {
    // set gate, add secret, encode/decode, verify ok / wrong fails
}
```

- [ ] **Step 2: Run — FAIL**
- [ ] **Step 3: Implement codec + helpers**
- [ ] **Step 4: `nix-shell --run "zig build test-vault"` PASS**
- [ ] **Step 5: Commit** `feat(domain): secrets gate verifier and secret list in KDAT`

---

### Task 3: Domain — bulk URL ingest by host

**Files:**
- Modify: `src/vault/domain.zig`
- Test: domain tests

**Interfaces:**
- Produces:
  - `pub fn extractHost(url: []const u8) ?[]const u8` — parse after `://`, until `/` `:` `?` `#`; lowercase into caller buffer OR return owned dupe
  - `pub fn normalizeHost(host: []const u8, out: []u8) []const u8` — lowercase; strip `www.` prefix
  - `pub fn ingestUrls(self: *Store, text: []const u8, now_ms: u64) DomainError!IngestResult` where `IngestResult = struct { created: u32, skipped_dup: u32, invalid: u32 };`
  - Scan text for `http://` / `https://` URLs (whitespace/newline separated; also tolerate bare lines)
  - For each URL: host collection under root (create if missing, name = normalized host); if entry with same `url` exists anywhere → `skipped_dup`; else `addEntry` with title = path tail or full URL truncated

- [ ] **Step 1: Failing test** with the user’s example multi-line paste (at least 3 distinct hosts: `simpcity.cr`, `bunkr.cr`/`bunkr.pk`, `cyberfile.me`)

```zig
test "ingestUrls groups by host and dedupes" {
    const sample =
        \\https://simpcity.cr/threads/ashley-alban.9988/page-2?order=reaction_score
        \\https://bunkr.pk/f/ZqgFmEqdng4QV
        \\https://bunkr.pk/f/ZqgFmEqdng4QV
        \\https://cyberfile.me/folder/83a8f2407979ea70afc06e2414bc3a47/Ashley_Alban_2024
    ;
    // expect collections for simpcity.cr, bunkr.pk, cyberfile.me
    // expect skipped_dup == 1
}
```

- [ ] **Step 2–4: TDD implement + `test-vault` PASS**
- [ ] **Step 5: Commit** `feat(domain): bulk URL ingest grouped by host`

---

### Task 4: Preview — og:image + capped image fetch

**Files:**
- Modify: `src/vault/preview.zig`
- Modify: `src/vault/tests.zig` (HTML fixtures; network tests only if existing harness allows — prefer parse unit tests + a fake-body image size gate)

**Interfaces:**
- Extend `Preview` / `OwnedPreview` with `image_url: []const u8` / owned image URL string
- `parseHtml` also reads `og:image` / `twitter:image`
- `pub const max_image_bytes: usize = 128 * 1024;`
- `pub fn fetchPreview(allocator, io_or_http, url, budget_ms) !OwnedPreviewWithImage` — if project already has HTTP helper, extend it; else implement minimal GET with timeout using existing patterns in `preview.zig` / vault tests
- Image step: if `image_url` present, GET bytes; if `len <= max_image_bytes` keep; else discard image
- Select path never calls fetch — document in comment

- [ ] **Step 1: Unit test** `parseHtml` extracts og:image from fixture string
- [ ] **Step 2–4: Implement + tests PASS**
- [ ] **Step 5: Commit** `feat(preview): og:image parse and capped image bytes`

---

### Task 5: AppController — activity Links|Senhas + gate session + ingest + preview cache paint

**Files:**
- Modify: `src/app_runner/app_controller.zig`
- Modify: `src/app_runner/app_dispatch.zig`
- Modify: `src/core.ts` (slots/msgs)
- Test: tests at bottom of `app_controller.zig` or new `src/app_runner/app_controller_tests.zig` wired in `build.zig` / `kak_app.zig`

**Interfaces:**
- Change `Activity` to `links = 0`, `senhas = 1` (remove search/lock-as-activity; Lock is button)
- Add slots: `senhas_gate_state` (0 unset, 1 locked, 2 unlocked), `senhas_error`, secret selection index
- Fields: `paste_buf`, `senhas_gate_unlocked: bool`
- `ingestPaste()` → `store.ingestUrls` → rebuild tree → optional enqueue preview refresh for new ids
- `selectEntry` / tree select: load editor + preview fields from Entry including `preview_image` pointer/len for view (no network)
- `onActivitySenhas`: if gate unset → UI create; else if not `senhas_gate_unlocked` → unlock form; else secrets list
- `createSenhasGate` / `unlockSenhasGate` using domain helpers; wrong → error code
- `lock()`: existing DEK drop + `senhas_gate_unlocked = false`
- Strip or no-op export/import/merge/settings from primary UX (leave code stubs only if removing breaks tests; prefer delete dead UI paths)

Msgs to add in `core.ts` + dispatch: `ingest_press`, `paste_input`, `senhas_gate_create`, `senhas_gate_unlock`, `secret_add`, `secret_save`, `secret_delete`, `activity_tab` values 0|1 only.

- [ ] **Step 1: Controller unit tests** for create vault → ingest → host collections; senhas gate weak reject; lock clears gate flag
- [ ] **Step 2–4: Implement + `nix-shell --run "zig build test -Dplatform=null"` PASS**
- [ ] **Step 5: Commit** `feat(app): links ingest and senhas gate session in controller`

---

### Task 6: Rewrite `app_view.zig` UI

**Files:**
- Modify: `src/app_runner/app_view.zig`
- Modify: `src/app_runner/app_keyboard.zig` (minimal)
- Modify: `src/app.native` if bindings required

**UI structure (must match spec):**

1. **Fresh:** title Kakuriyo, master password, confirm, Create
2. **Locked:** password, Unlock
3. **Unlocked Links:** top `Links | Senhas | Lock`; paste multiline + Ingerir; tree | editor | preview (thumbnail placeholder or image bytes if view API supports bitmap — if bitmap unsupported in canvas widgets, show “thumbnail cached (N bytes)” + title/description until image widget exists; prefer real image if `ui.image`/`texture` available in Native SDK primitives)
4. **Senhas:** create gate / unlock gate / secret list+editor

Keep TRUE BLACK / existing token style if present; avoid purple-on-white. One clear composition per screen.

- [ ] **Step 1: Implement view branches** driven by `phase` + `activity` + `senhas_gate_state`
- [ ] **Step 2: `nix-shell --run "native check --strict"`** (or gate-check script) PASS
- [ ] **Step 3: Manual `./run.sh` smoke if DISPLAY available** — auth screens render
- [ ] **Step 4: Commit** `feat(ui): auth links senhas shells`

---

### Task 7: Preview refresh path + select SLA oracle

**Files:**
- Modify: `app_controller.zig` (`refreshPreview` for selected / post-ingest)
- Modify: tests

**Behavior:**
- `refresh_preview` / after ingest: call preview fetch with budget; `store.setPreview`; mark dirty; save when existing save path runs
- Select path oracle: fill Entry with preview fields; call select; assert view model / controller preview getters return cached data; assert test does not invoke network (inject null transport or flag)

- [ ] **Step 1: Test** `select uses cache without fetch`
- [ ] **Step 2–4: Implement + PASS**
- [ ] **Step 5: Commit** `feat(preview): cache-first select and budgeted refresh`

---

### Task 8: Gates, smoke, e2e, ledger

**Files:**
- Modify: `tools/gates/gates.sh`, `GATES.md`, `.scratch/kakuriyo/prove/ledger.md`
- Modify/Create: smoke driver under `tools/smoke/` to exercise controller headless:
  1. fresh create master
  2. lock/unlock
  3. ingest sample URLs → hosts
  4. select entry with preloaded preview_image → instant cache hit
  5. senhas gate create/unlock/secret CRUD
  6. lock clears gate session

- [ ] **Step 1: Add smoke steps that exit non-zero on failure**
- [ ] **Step 2: Wire into `npm run gate`**
- [ ] **Step 3: Run full gate**

```bash
cd /mnt/Others/Projects/PersonalProjects/Kakuriyo
nix-shell --run "npm run gate"
```

Expected: all PASS.

- [ ] **Step 4: Commit** `test: gates and smoke for ui redesign flows`

---

### Task 9: Dogfood + README + ship closeout

**Files:**
- Modify: `README.md` (how to run, master/Senhas/Links flows)
- Update plan checkboxes as done

- [ ] **Step 1: Dogfood checklist (real binary if display; else headless smoke evidence)**
  - [ ] Create master with confirm
  - [ ] Unlock
  - [ ] Paste multi-URL sample from spec → host collections appear
  - [ ] Select entry → preview meta/thumb cache path works
  - [ ] Senhas first visit → weak password rejected; strong accepted
  - [ ] Add secret; lock; unlock master; Senhas requires gate again
- [ ] **Step 2: README update**
- [ ] **Step 3: Final `nix-shell --run "npm run gate"` PASS**
- [ ] **Step 4: Commit** `docs: README for redesigned vault UI`
- [ ] **Step 5: Push branch, open PR, merge**

```bash
git push -u origin HEAD
gh pr create --title "feat: Kakuriyo UI redesign (Links + Senhas)" --body "$(cat <<'EOF'
## Summary
- Master create/unlock UX
- Links bulk ingest by host + cache-first preview thumbnails
- Senhas tab with separate strong gate + secret CRUD
- Gates/smoke cover the flows

## Test plan
- [x] `nix-shell --run \"npm run gate\"`
- [x] Dogfood checklist in plan Task 9
EOF
)"
gh pr merge --merge
```

(If already on `main` with local commits: create branch `feat/ui-redesign` from current work before push if repo policy requires PR ≠ direct main push.)

---

## Spec coverage checklist (planner self-review)

| Spec requirement | Task |
|------------------|------|
| Master create + unlock | 5, 6, 8, 9 |
| Senhas second gate + 4 classes | 2, 5, 6, 8, 9 |
| Gate on first Senhas visit | 5, 6 |
| Bulk paste group by host | 3, 5, 6 |
| Preview &lt;1s from cache | 1, 4, 7, 8 |
| Thumbnail ≤128KiB in vault | 1, 4, 7 |
| Lock clears gate session | 5, 8 |
| No export/import/Vim in ship | 5, 6 (strip/ignore) |
| Gates/smoke/e2e | 8, 9 |
| PR + merge | 9 |

## Placeholder scan

No TBD steps. Image paint falls back to “cached N bytes” if SDK lacks image widget — still satisfies storage + SLA oracles.

## Type consistency

- `Activity.links|senhas`
- `SecretsGate` / `Secret` / `ingestUrls` / `setPreview` names used consistently across tasks
- Commits via `git-safe-commit -m`
