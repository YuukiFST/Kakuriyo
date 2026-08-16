# Vault v1 Envelope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the Kakuriyo Native SDK app (TS core + `.native` markup, ejected build), wire a Zig `vault.*` host service over `Cmd.request`/`bindHostCalls`, and close the Vault v1 envelope (create / Unlock / Lock / change Master Password / atomic save with Argon2id KEK + random DEK + XChaCha20-Poly1305 + `secureZero`), proven by /prove oracles (T2: envelope crypto + Unlock/Lock state machine) with gates that exit non-zero.

**Architecture:** The app is a zero-config Native SDK TS-core app (`src/core.ts` + `src/app.native` + `app.zon`) whose build we own via `native eject` (`--full`). The SDK's staged TS wiring (`ts_core_main.zig`) has no public hook for app Zig code, so we vendor the SDK's `build/app.zig` into `build/kak_app.zig` (CLI 0.8.3, commit 30c1410) with three surgical patches: stage the app-owned `src/app_runner/ts_core_main.zig` instead of the SDK copy, and stage `src/vault/*.zig` beside it. The app-owned wiring binds `HostCallBinding` via `app_state.effects.bindHostCalls(...)` with `request_fn` dispatching `vault.*` names and answering through `feedHostResult`. The vault module is pure `std` Zig (no `native_sdk` import), so it unit-tests without GTK. The TS core is a pure state machine (phases fresh/locked/unlocked, guarded transitions) that never stores the password and clears plaintext payload on Lock.

**Tech Stack:** Native SDK CLI 0.8.3 (vercel-labs/native), TypeScript subset (`@native-sdk/core`), Zig 0.16.0 `std.crypto` only (`argon2.kdf`, `XChaCha20Poly1305`, `std.Io.random`, `secureZero`, `Io.Dir.createFileAtomic`), Node 24 (`--experimental-strip-types` harness), NixOS dev shell (`zig`, `gtk4`, `pkg-config`).

## Global Constraints

- Algorithms are locked by `.scratch/kakuriyo/spec.md` + research/03 + research/12: Argon2id KEK (baseline `Params.owasp_2id` = `{ t=2, m=19*1024, p=1 }`, persisted beside salt), random 32-byte DEK from CSPRNG, XChaCha20-Poly1305 (24-byte nonces, 16-byte tag), AAD binds format version, `secureZero` on Lock; password never persisted; payload never re-encrypted on password change (rewrap DEK only).
- TS core lives in the subset: no npm packages, no `JSON`, no `Date.now()`/`Math.random()` in `update`, no `Map`/`Set`; text is `Uint8Array`; effects are `Cmd` data; result arms take exactly one `Uint8Array` field; host-dispatched arms go in `viewUnbound`.
- Crypto stays in Zig `std`; no `Cmd.spawn` sidecar, no pure-TS Argon2.
- Host protocol names are `vault.create`, `vault.unlock`, `vault.save`, `vault.change_password`, `vault.lock` (fire-and-forget `Cmd.host`); errors are ASCII code bytes.
- Atomic save = temp → fsync → rename (replace semantics), one vault file.
- Vault file: fixed-width versioned header, format v1 (layout below); on-disk path owned by the Zig host (the wiring resolves the default app-data path; tests use temp dirs).
- Gates must exit non-zero; one command runs all gates; the gate set is `tools/gates/gates.sh`, wired into `.github/workflows/ci.yml`.
- Commits: Conventional Commits (EN) via `git-safe-commit`; author YuukiFST `<faustoyuuki@gmail.com>` (already configured); ask the user before `push`; no Co-authored-by.
- Out of scope: Unlock UI, CRUD, Preview, Export/Import, packaging (spec steps 3–9), Fog items.

## Locked protocols (used by every task below)

### Vault file format v1 (128-bit aligned fixed header + ciphertext)

```
offset   size   field
0        4      magic "KAKU"
4        4      version u32be = 1
8        4      argon2 m_cost u32be (KiB)
12       4      argon2 t_cost u32be
16       4      argon2 p_cost u32be
20       16     salt
36       24     dek_nonce            (XChaCha nonce for the DEK wrap)
60       48     wrapped_dek          (32-byte DEK ciphertext + 16-byte tag)
108      24     payload_nonce        (XChaCha nonce for the payload)
132      rest   payload_ct           (payload + 16-byte tag)
```

- AAD for both AEAD calls: ASCII `kakuriyo/vault-v1` (17 bytes) — binds the version.
- Validation on load: magic, `version == 1`, `8 <= m_cost <= 2^22`, `1 <= t_cost <= 100`, `1 <= p_cost <= 16`, file length >= 133 (formats: 133 + tag guard). Any failure → `error.Corrupt`; `version != 1` → `error.UnsupportedVersion`.
- Password bounds: `1..=1024` bytes. Payload bound: `<= 64 MiB` (beyond → `error.PayloadTooLarge`).

### Host request protocol (TS → Zig payload framing)

Every payload is a field list: `[n_fields:u8] { [len:u32be] [bytes] }*`. Op arities: `vault.create` 1 (password), `vault.unlock` 1 (password), `vault.save` 1 (plaintext payload), `vault.change_password` 2 (current, next), `vault.ping` 1 (echo bytes). `vault.lock` rides `Cmd.host` (no key, no result) and ignores its payload.

### Error codes (ASCII bytes in the err route)

`bad_request`, `unknown`, `not_found`, `wrong_password`, `corrupt`, `unsupported_version`, `already_exists`, `locked`, `io_failed`, `out_of_memory`, `params_invalid`, `payload_too_large`.

### Zig module API (src/vault/vault.zig, pure std)

```zig
pub const magic = "KAKU";
pub const version: u32 = 1;
pub const aad = "kakuriyo/vault-v1";
pub const salt_len = 16; pub const dek_nonce_len = 24; pub const payload_nonce_len = 24;
pub const key_len = 32; pub const tag_len = 16;
pub const wrapped_dek_len = key_len + tag_len;   // 48
pub const header_len = 132;
pub const max_password_len = 1024; pub const max_payload_len = 64 * 1024 * 1024;

pub const KdfParams = struct { m_cost: u32, t_cost: u32, p_cost: u32 };
pub fn defaultParams() KdfParams;   // { 19*1024, 2, 1 } (owasp_2id)

pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,               // owned copy
    unlocked: bool = false,
    dek: [key_len]u8 = undefined,   // live only while unlocked
    payload: ?[]u8 = null,          // owned plaintext, zeroed+freed on lock

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) error{OutOfMemory}!Session;
    pub fn deinit(self: *Session) void;                                   // lock() + free(path)
    pub fn create(self: *Session, password: []const u8, params: KdfParams) CreateError!void;   // also unlocks
    pub fn unlock(self: *Session, password: []const u8) UnlockError![]const u8;               // returns payload view (owned by session)
    pub fn save(self: *Session, payload: []const u8) SaveError!void;
    pub fn changePassword(self: *Session, current: []const u8, next: []const u8) ChangeError!void;
    pub fn lock(self: *Session) void;                                     // secureZero dek + payload, unlocked = false
};
```

Errors: `CreateError = error{ AlreadyExists, Io, OutOfMemory, ParamsInvalid, PayloadTooLarge }`, `UnlockError = error{ NotFound, Corrupt, UnsupportedVersion, WrongPassword, Io, OutOfMemory, PayloadTooLarge }`, `SaveError = error{ Locked, Io, OutOfMemory, PayloadTooLarge }`, `ChangeError = error{ Locked, WrongPassword, Io, OutOfMemory }`.

### Host adapter (src/vault/vault_host.zig, pure std)

```zig
pub const ResultFn = *const fn (ctx: *anyopaque, key: u64, ok: bool, bytes: []const u8) void;
pub const State = struct {
    session: vault.Session,
    result_ctx: *anyopaque, result_fn: ResultFn,   // wiring injects the feedHostResult adapter
    pub fn init(...) error{OutOfMemory}!State;
    pub fn deinit(self: *State) void;
};
pub fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void;      // vault.lock
pub fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void;  // answers exactly once
```

### TS core surface (src/core.ts)

```ts
export type Phase = "fresh" | "locked" | "unlocked";
export interface Model { readonly phase: Phase; readonly payload: Uint8Array; readonly error: Uint8Array; readonly lastPing: Uint8Array; }
export type Msg =
  | { readonly kind: "create_attempt"; readonly password: Uint8Array }
  | { readonly kind: "created" } | { readonly kind: "create_failed"; readonly reason: Uint8Array }
  | { readonly kind: "unlock_attempt"; readonly password: Uint8Array }
  | { readonly kind: "unlocked"; readonly payload: Uint8Array } | { readonly kind: "unlock_failed"; readonly reason: Uint8Array }
  | { readonly kind: "save_attempt"; readonly payload: Uint8Array }
  | { readonly kind: "saved" } | { readonly kind: "save_failed"; readonly reason: Uint8Array }
  | { readonly kind: "change_attempt"; readonly current: Uint8Array; readonly next: Uint8Array }
  | { readonly kind: "changed" } | { readonly kind: "change_failed"; readonly reason: Uint8Array }
  | { readonly kind: "lock" }
  | { readonly kind: "ping_attempt"; readonly payload: Uint8Array }
  | { readonly kind: "pinged"; readonly payload: Uint8Array } | { readonly kind: "ping_failed"; readonly reason: Uint8Array };
export const viewUnbound = ["created", "create_failed", "unlocked", "unlock_failed", "saved", "save_failed", "changed", "change_failed", "pinged", "ping_failed"] as const;
```

State rules: `save_attempt`/`change_attempt` only when `phase == "unlocked"` (else no Cmd, error bytes `"locked"`); `lock` issues `Cmd.host("vault.lock")`, sets `phase = "locked"`, clears `payload`; success arms set phase (create/unlock → `"unlocked"`, save/change → unchanged); failure arms keep phase, set `error` bytes; `lock` allowed from any phase. Password bytes never enter the model.

---

## Task 0: Scaffold the app and prove the NixOS build env

**Files:**
- Create: `app.zon`, `assets/icon.png`, `src/core.ts`, `src/app.native`, `build.zig`, `build.zig.zon`, `package.json`, `tsconfig.json`, `.gitignore`, `README.md` (all from `native init --full`), `shell.nix`

- [ ] **Step 1: Scaffold with owned build**

```bash
cd /tmp && rm -rf kakuriyo-scaffold && native init kakuriyo-scaffold --full
cd /mnt/Others/Projects/PersonalProjects/Kakuriyo
# move the scaffold into the repo root (repo has .scratch/ docs/ CONTEXT.md README.md)
rsync -a --exclude .git /tmp/kakuriyo-scaffold/ ./
```

- [ ] **Step 2: Rename identity to the product**

Edit `app.zon`: `id = "dev.yuukifst.kakuriyo"`, `name = "kakuriyo"`, `display_name = "Kakuriyo"`, `description = "Local encrypted personal vault for private Entries, organized in nested Collections."`, `.platforms = .{ "linux", "windows" }`; keep the scaffold's counter window (replaced in Task 1). Edit `build.zig.zon`: `.name = .kakuriyo`; extend `.paths` to `.{ "build.zig", "build.zig.zon", "src", "assets", "app.zon", "README.md", "build", "tests", "tools" }` (the vendored build files under `build/` must be inside the package paths or `zig build` refuses the import).

- [ ] **Step 3: Nix dev shell**

Create `shell.nix`:

```nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = [ pkgs.zig pkgs.gtk4 pkgs.pkg-config pkgs.nodejs_24 ];
}
```

- [ ] **Step 4: Prove the environment: `native check` + first `native build`**

```bash
nix-shell --run "native check && native build --yes"
```

Expected: `native check` clean (subset + markup + app.zon); `native build` produces `zig-out/bin/kakuriyo` (ReleaseFast; first run compiles the SDK — minutes). If GTK4 or pkg-config is missed, adjust `shell.nix` (this step exists to fail here, cheaply).

- [ ] **Step 5: Baseline the failure state before any gates exist** — note `native test` currently passes with zero app tests. Commit:

```bash
git add -A && git-safe-commit "chore: scaffold Native SDK app (TS core, ejected build)"
```

---

## Task 1: Host-call seam — vendored build, owned wiring, `vault.ping` round-trip

**Files:**
- Create: `build/kak_app.zig` (vendored SDK `build/app.zig`, patched), `build/kak_web_layer.zig` (vendored `web_layer.zig`, enums inlined), `src/app_runner/ts_core_main.zig` (app-owned wiring), `src/vault/vault_host.zig` (ping-only State + dispatch), `src/app_runner/host_roundtrip_tests.zig`
- Modify: `build.zig`, `src/core.ts`, `src/app.native`, `build.zig.zon` (already has `build` in paths)

**Interfaces (re-scoped):**
- Consumes: `AddAppOptions` from vendored build; `native_sdk.runtime.HostCallBinding`; `Effects.bindHostCalls`; `vault_host.State`. (`Cmd.request`/`Cmd.host` remain the CONTRACT for Tasks 3/5 but cannot ride the compiled core lane on 0.8.3 — see the research note; the ops table is driven at the binding level instead.)
- Produces: `kak_sdk_app.addApp(b, dep, .{ .name = "kakuriyo" })`; wiring exports `pub const core`/`vault`/`vault_host`, `createAppState(io, allocator, environ_map) !*App`, `installHostCalls(...) !*vault_host.State`, `defaultVaultPath`, `canvas_label`; `vault_host.State` with `sendFn`/`requestFn`; core `ping_attempt`/`pinged`/`ping_failed` msgs (void arms, number-only model).

- [ ] **Step 1: Vendor the build helper (verbatim + 3 patches)**

```bash
CLI=$(npm root -g)/@native-sdk/cli
mkdir -p build src/app_runner src/vault
cp "$CLI/build/app.zig" build/kak_app.zig
```

Patch `build/kak_app.zig`:
1. Replace the header (first 2 lines) with an ownership header: vendored from `@native-sdk/cli` 0.8.3 (commit 30c1410), Apache-2.0; list the patches below and the re-vendor command (`diff -u "$CLI/build/app.zig" build/kak_app.zig`).
2. `const web_layer_contract = @import("../src/primitives/app_manifest/web_layer.zig");` → `@import("kak_web_layer.zig");`.
3. In `tsCoreStage`, replace `const main_root = staged.addCopyFile(dep.path("src/app_runner/ts_core_main.zig"), "main.zig");` with:

```zig
const main_root = staged.addCopyFile(b.path(appPath(b, app_options.app_root, "src/app_runner/ts_core_main.zig")), "main.zig");
_ = staged.addCopyFile(b.path(appPath(b, app_options.app_root, "src/vault/vault.zig")), "vault.zig");
_ = staged.addCopyFile(b.path(appPath(b, app_options.app_root, "src/vault/vault_host.zig")), "vault_host.zig");
```

Then create `build/kak_web_layer.zig`: verbatim copy of `"$CLI/src/primitives/app_manifest/web_layer.zig"` with `const types = @import("types.zig");` replaced by the two enums inlined verbatim from `"$CLI/src/primitives/app_manifest/types.zig"` lines 83–100 (`pub const WebEngine = enum { system, chromium };` and `pub const WebViewLayer = enum { auto, include, exclude };` — copy the real source text), plus the same ownership header.

- [ ] **Step 2: Point the app build at the vendored helper**

Rewrite `build.zig`:

```zig
const std = @import("std");
const kak_sdk_app = @import("build/kak_app.zig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    kak_sdk_app.addApp(b, dep, .{ .name = "kakuriyo" });
}
```

Run `nix-shell --run "native check"` — must stay clean (proves the vendored helper parses; it will panic on a wrong dependency shape).

- [ ] **Step 3: App-owned wiring with host-call binding**

Copy the SDK wiring: `cp "$CLI/src/app_runner/ts_core_main.zig" src/app_runner/ts_core_main.zig` and apply the Kakuriyo diff:
1. Header: note it is the app-owned copy of SDK `ts_core_main.zig` 0.8.3, extended with the vault host binding (re-vendor command documented).
2. After `pub const core = @import("core.zig");` add:

```zig
pub const vault = @import("vault.zig");
pub const vault_host = @import("vault_host.zig");
```

3. Extract the adapter construction from `main()` into:

```zig
pub fn createAppState(io: std.Io, allocator: std.mem.Allocator) !*App {
    var options: Adapter.Options = .{ /* the exact options main() builds today, scene/canvas/markup/theme/theme_accent */ };
    if (comptime @hasDecl(core, "commandMsg")) options.on_command = core.commandMsg;
    var cache_dir_buffer: [512]u8 = undefined;
    const audio_cache_dir = native_sdk.app_dirs.resolveOne(.{ .name = manifest.name }, native_sdk.app_dirs.currentPlatform(), native_sdk.debug.envFromMap(init_environ_map), .cache, &cache_dir_buffer) catch "";
    // + image cache dir, boot images, env values — move the existing main() bodies verbatim, taking init.io / allocator as parameters
    return try Adapter.create(allocator, .{ .audio_cache_dir = ..., .image_cache_dir = ..., .boot_images = ..., .env_values = ... }, options);
}
```

(`envFromMap` needs the environ map — keep the `init`-independent pieces parameterized: `createAppState(io, allocator, environ_map)`; keep the signature honest — see the real main() before writing.) `main()` becomes: `var app_state = try createAppState(init.io, std.heap.page_allocator, init.environ_map);` then host install + `runWithOptions`.

4. Add the host install + a test seam at the bottom:

```zig
pub fn installHostCalls(app_state: *App, io: std.Io, allocator: std.mem.Allocator, vault_path: []const u8) !void {
    const vault_state = try allocator.create(vault_host.State);
    vault_state.* = try vault_host.State.init(io, allocator, vault_path, .{
        .result_ctx = app_state.effects.resultSinkContext(),   // see Step 4
        .result_fn = feedHostResultFn,
    });
    app_state.effects.bindHostCalls(.{
        .context = vault_state,
        .send_fn = vault_host.sendFn,
        .request_fn = vault_host.requestFn,
    });
}
```

5. In `main()`, resolve the vault path with `native_sdk.app_dirs` (config dir + `"vault.kakuriyo"`, the same `resolveOne` pattern as the audio cache dir) and call `installHostCalls` after `createAppState`, `defer`ing the vault state deinit. In Task 1 the `vault.ping` op does a synchronous echo.

- [x] **Steps 1–3: DONE (vendored build, owned wiring, host binding)** — the vendored `kak_app.zig`/`kak_web_layer.zig`, app-owned `ts_core_main.zig` (exports `createAppState`, `installHostCalls` returning `*vault_host.State`, `defaultVaultPath`, `canvas_label`), `bindHostCalls` bound with `vault_host.sendFn`/`requestFn`; `zig build test` green since the Task 1 baseline (16/16 steps, 15/15 tests).

- [x] **Step 4 (re-scoped): Mirror types read; round-trip tests written at the BINDING** — the staged `core.zig` mirror was read (see the seam). The routed round trip CANNOT run through the TS core on this SDK version: the scriptc compiled lane frees every compiled-side allocation at cycle end, so a routed (second-cycle) dispatch reads the committed root from a reused block, and enum/model slots trap (full evidence: `.scratch/kakuriyo/research/ts-core-lane-limits.md`; see also the core.ts header note). `src/app_runner/host_roundtrip_tests.zig` therefore proves the seam as:
  1. `the app loop survives sequential dispatches with an intact model` — real dispatch/drain cycles on the live harness; the number-slot model stays readable (the only lane-stable shape);
  2. `vault_host echoes arbitrary byte payloads verbatim` — the REAL bound `request_fn` answers its feedHostResult-shaped sink with exactly the payload bytes, empty included;
  3. `unknown vault.* names reject through the err route` — the err-wire contract (ok=false, "unknown");
  4. `vault_host.sendFn observes fire-and-forget commands` — the Cmd.host lane (vault.lock's Task 3 transport).

- [x] **Step 5 (re-scoped): Minimal core + markup + host adapter** — `src/core.ts`: `Model { echo: f64 }` (-0.5 initial), void `ping_attempt` returning the root unchanged, no `Cmd` issuance (the lane cannot carry commands — SC1100 on `Cmd.host` returns, root corruption on `Cmd.request` routes); `viewUnbound = ["pinged", "ping_failed"]` reserved. `src/vault/vault_host.zig`: `State { io, allocator, path, sink }` + `requestFn` (vault.ping echo, else "unknown") + `sendFn` (observes, no-op otherwise).

- [x] **Step 6 (re-scoped): Run the test to green** — `nix-shell --run "zig build test -Dplatform=null"` = 15/15 pass, no leaks; `native check` clean. The REAL-channel side of the round trip is proven at the binding because the compiled lane cannot host the routed cycle; the plan's Task 5 smoke therefore runs the ENVELOPE session at the Zig level (vault_host.requestFn with the real ops) and observes results through the sink.

- [x] **Step 7: Gate seen failing** — a temporary wrong arm (unknown name wired into `requestFn`) fails the reject test; reverted (was verified during the bisect: the tap tests 2/3 fail when `vault.ping` stops echoing).

- [x] **Step 8: Committed** — `git-safe-commit` (author YuukiFST) after the audit below; push awaits user.

---

## Task 2: Vault v1 envelope — oracles first, then `vault.zig`

**Files:**
- Create: `src/vault/vault.zig` (implementation + `test` blocks), `src/vault/tests.zig` (test module root), `tools/gates/gate-vault.sh`, `tools/gates/gate-mutate.sh` (mutants M1–M8 land here; run against the Task 2 tests)

**Interfaces:**
- Consumes: `vault.Session` API above; `std.testing.tmpDir`; `std.Io` from `std.testing.io_instance`.
- Produces: `Session` with the full envelope; `zig build test-vault` step (std-only module, no GTK); the vault file format above.

- [ ] **Step 1: Spike the std plumbing** (compile a 20-line scratch under `nix-shell -p zig` first): exact spellings for `std.testing` Io in tests, `std.testing.tmpDir(.{})` usage, `Io.Dir.openDirAbsolute` (or `cwd()`) + `createFileAtomic` + `file.sync(io)` + `Atomic.replace(io)`, `argon2.kdf` allocator argument, `XChaCha20Poly1305.encrypt/decrypt` argument order (from `std/crypto/chacha20.zig` lines 735/749), `std.crypto.secureZero(u8, &buf)` coercions. Write the found spellings into this task's steps (replace anything that drifts).

- [x] **Step 2: Write the oracle tests inside `vault.zig` first** (they must not compile / must fail). From research/03 + spec only — no implementation in view:

  - `test "create writes v1 file and unlocks"` — temp path; `create(pw, defaultParams())`; read the file (via the temp dir's `dir` handle + `readFileAlloc`): magic `KAKU`, `version == 1`, m/t/p == owasp baseline, salt 16, nonces 24, wrapped_dek 48, total length == `header_len + tag_len` (empty payload); `session.unlocked`.
  - `test "roundtrip across payload sizes"` — sizes `{ 0, 1, 16, 255, 1024, 65536 }` with deterministic byte patterns; create → save → lock → unlock → payload identical; also unlock immediatley after create returns the empty payload.
  - `test "wrong password fails cleanly"` — create, lock, unlock("nope") → `error.WrongPassword`, still locked; the file bytes are unchanged after the failed attempt (re-read + compare).
  - `test "tampered ciphertext fails authentication"` — create+save, flip one byte in the payload ciphertext region, unlock → `error.WrongPassword`.
  - `test "tampered header is corrupt"` — flip magic → `error.Corrupt`; set `version = 2` → `error.UnsupportedVersion`; truncate file by 3 bytes → `error.Corrupt`.
  - `test "password change rewraps DEK without re-encrypting payload"` — create, save payload, snapshot: `payload_nonce` + `payload_ct` bytes; `changePassword(cur, next)`; assert `salt`, `wrapped_dek`, `dek_nonce` changed and the payload region is byte-identical; lock; unlock with `next` → same payload; unlock with `cur` → `error.WrongPassword`.
  - `test "save while locked is rejected"` — after lock, `save` → `error.Locked` and file unchanged.
  - `test "create on existing vault fails"` — double create → `error.AlreadyExists`.
  - `test "unlock missing vault fails"` — `error.NotFound`.
  - `test "lock zeroes secrets"` — unlock, then `lock()`; assert `dek` is all zeros, `payload` buffer all zeros, `unlocked == false`.
  - `test "atomic save leaves one valid file"` — 3 consecutive saves; after each: unlock fails with the OLD password? (no — payload changes do not change password); instead assert: the directory contains exactly one vault file (no `.tmp`/hex leftovers — list the tmp dir), and the on-disk file always passes a fresh `unlock` with correct payload (no torn read).
  - `test "save rotates payload nonce"` — two saves of the same payload produce different `payload_nonce` + `payload_ct`.
  - `test "password bounds"` — empty password → `error.PasswordInvalid`-class rejection (pick the error name while writing the test; create/unlock/change share the bound); 1025-byte password rejected.
  - `test "consecutive kdf params are persisted"` — create with non-default params `{ 8192, 1, 2 }` → file header matches; unlock works.
  - Property sweep (stdlib loop, fixed seed): for 40 random payloads (sizes via `std.Random.DefaultPrng` seeded constant), round-trip holds; note: keys/nonces come from the CSPRNG; patterns are deterministic.

- [x] **Step 3: Run the oracles — expected FAIL/compile errors**

`nix-shell --run "zig test src/vault/vault.zig"` → fails with `error: root source file ... has no member named 'Session'` (or similar). Record the failures as the baseline.

- [x] **Step 4: Implement `vault.zig`**

`Session` per the API above. Notes for the implementer:
- `create`: `io.random` (CSPRNG) for salt/nonces/DEK; `argon2.kdf(allocator, &kek, password, salt, params, .argon2id)`; wrap DEK with the DEK nonce; `secureZero(kek)` immediately after; encrypt empty payload; atomic write; store DEK + payload; `unlocked = true`.
- `unlock`: read file → parse/validate header → kdf → `XChaCha20Poly1305.decrypt` wrapped DEK → on `error.AuthenticationFailed` → `error.WrongPassword` (never distinguish the failure for a missing file vs a bad password — keep `NotFound` distinct); decrypt payload → store.
- `save`: `locked` guard; fresh payload nonce; encrypt; atomic write.
- `changePassword`: `locked` guard; verify `current` by unwrapping the DEK (auth failure → `WrongPassword`); fresh salt + params? (spec: "new salt/params → new KEK → re-wrap same DEK" — new salt, keep the stored params unless caller passes new ones — take `params` argument with default), rewrap, write only the header region (rewrite the whole file with the payload region copied unmodified — assert byte-identity in the oracle).
- Atomic write: parent dir handle (`openDirAbsolute` on the dirname), `createFileAtomic(parent, io, basename, .{ .replace = true })`, `file.writeAll(io, ...)`, `file.sync(io)`, `atomic.replace(io)`, then best-effort dir fsync if the Io exposes it; on any failure, `atomic.deinit(io)` removes the temp.
- `lock`: `secureZero(u8, &self.dek)`, payload: `secureZero` then free; every error path that produced a KEK/password copy zeroes before returning.

- [x] **Step 5: Green**

`nix-shell --run "zig test src/vault/vault.zig"` — all oracles pass. `zig fmt src/vault/`.

- [x] **Step 6: Register the fast gate**

Append to `build.zig`:

```zig
    const vault_tests = b.addTest(.{ .root_source_file = b.path("src/vault/tests.zig"), .target = b.graph.host, .optimize = .Debug });
    const vault_test_step = b.step("test-vault", "Run vault envelope unit tests (std-only, no GTK)");
    vault_test_step.dependOn(&b.addRunArtifact(vault_tests).step);
```

with `src/vault/tests.zig` = `comptime { _ = @import("vault.zig"); _ = @import("vault_host.zig"); }` (vault_host arrives in Task 3 — write the import then; for Task 2 only `vault.zig`). Verify `nix-shell --run "zig build test-vault"` runs the suite. Also verify the app still builds: `nix-shell --run "native build"` (the wiring's staged `vault.zig` import exists from Task 1 — keep a minimal `Session = struct{}` stub in `vault.zig` ONLY if Task 2 lands before Task 1's adapter is adapted; otherwise merge cleanly).

- [x] **Step 7: Mutation gate (first 8 mutants) — installed and seen failing**

Create `tools/gates/mutate.sh`: a loop over mutant descriptors `name|target_file|sed_expression|test_command` where each iteration applies sed → runs the named test command → expects non-zero → reverts via `git checkout -- <file>` (or `cp` backup). Non-zero everywhere except the mutant's own pass-through. Mutants (vault.zig, run `zig build test-vault`):

```
M1 wrong_aad|src/vault/vault.zig|s/kakuriyo\/vault-v1/kakuriyo\/vault-v2/   -> roundtrip/tamper tests must fail
M2 constant_nonce|use the DEK nonce as the payload nonce (patch the save line) -> "save rotates nonce" + consecutive-save tests fail
M3 no_zero_on_lock|delete the secureZero call in lock()                       -> "lock zeroes secrets" fails
M4 ignore_auth_error|drop the decrypt() error check in unlock                 -> "wrong password" + "tampered ciphertext" fail
M5 reuse_dek|derive DEK from password (remove the CSPRNG DEK)                 -> "password change rewraps" + "create writes" fail (salt/DEK bindings)
M6 no_atomic|write the file directly (skip createFileAtomic)                  -> "atomic save leaves one valid file" + tamper tests fail
M7 no_rewrap|changePassword re-encrypts payload (call save instead)           -> "rewraps without re-encrypting" fails
M8 no_version_bind|use AAD without the version                               -> "tampered header" (version flip) test must fail
```

Disposition rule: any mutant whose expected tests pass = survivor → script exits 1 and names it. For a scripted `sed` that cannot express a mutant reliably, apply the patch with a heredoc `perl -0pi`; if a mutant cannot be mechanically applied, annotate it in the ledger as equivalent/skipped with the reason (never silently).

- [x] **Step 8: Commit**

```bash
git add src/vault build.zig tools/gates && git-safe-commit "feat: close vault v1 envelope (argon2id KEK + XChaCha20-Poly1305 + atomic save)"
```

---

## Task 3: Host dispatch — full `vault.*` protocol over frames

**Files:**
- Modify: `src/vault/vault_host.zig` (full State + dispatch), `src/vault/vault.zig` (no — unchanged), `src/vault/tests.zig` (add `vault_host` import), `src/vault/vault_host_tests.zig` (new test block)

**Interfaces:**
- Consumes: `vault.Session`; the framing in "Locked protocols".
- Produces: `requestFn`/`sendFn` covering all five ops; error codes as listed; the wiring passes `result_fn` = thin adapter calling `effects.feedHostResult(key, ok, bytes)` (note `feedHostResult` returns `error{EffectNotFound}` — ignore in the adapter, the channel rejects late results itself).

- [ ] **Step 1: Write the failing dispatch tests** (`src/vault/vault_host_tests.zig`, imported from `tests.zig`). A recording sink: `result_fn` copies `(key, ok, bytes)` into a fixed buffer, indexed by a counter. Tests:

  - `test "create and unlock via dispatch"` — frame(password) → `requestFn("vault.create")` → ok, empty; frame(password) → `vault.unlock` → ok with empty payload; save frame(payload) → ok; lock via `sendFn("vault.lock")`; unlock → ok + payload bytes.
  - `test "wrong password maps to wrong_password"` — unlock with a bad frame → ok=false, bytes == `"wrong_password"`.
  - `test "unknown host name rejects"` — `vault.nope` → ok=false, `"unknown"`; sendFn with unknown name is a silent no-op.
  - `test "malformed frames map to bad_request"` — {0 fields}, {declared 2 but 1 present}, {len overruns payload}, {n_fields garbage} → ok=false, `"bad_request"`; no crash, exactly one answer per request.
  - `test "save while locked maps to locked"`.
  - `test "create on existing vault maps to already_exists"`.
  - `test "missing vault maps to not_found"`.
  - `test "change password via dispatch rewraps"` — full lifecycle through frames.
  - `test "failing ops never leave the session unlocked"` — after each failing op, a subsequent correct unlock still works.

  Expected: FAIL (no dispatch).

- [x] **Step 2: Implement the dispatch** — frame parser (bounds-checked), op table, error-code mapping, `sendFn` handling `vault.lock` only; every `requestFn` path answers exactly once (guard: an internal `answered` flag per call — a request that could not be answered is answered `ok=false "internal"`).

- [x] **Step 3: Green** — `nix-shell --run "zig build test-vault"`.

- [x] **Step 4: Wire the real ops into the effects channel** — Task 1's round-trip test is extended in Task 5; for now verify the wiring still compiles: `nix-shell --run "native check && zig build test"` (the app module now carries the full module).

- [x] **Step 5: Commit** — `git-safe-commit "feat: dispatch vault.* host ops over framed protocol"`.

---

## Task 4: TS core session state machine

**Files:**
- Create: `tests/core-logic.test.mjs`, `tools/gates/gate-ts.sh`
- Modify: `src/core.ts` (full surface from "Locked protocols"), `src/app.native` (phase + payload + error + lastPing text), `package.json` scripts (`"test:core"`, `"gate"`)

**Interfaces:**
- Consumes: `@native-sdk/core` (`Cmd`, `asciiBytes`) resolved by the CLI-materialized `node_modules`; node 24 type stripping.
- Produces: the full `Model`/`Msg`/`update`; `tests/core-logic.test.mjs` exercises `update` directly under node with a recording host.

- [ ] **Step 1: Write the acceptance oracles (node harness, no implementation in view)**

`tests/core-logic.test.mjs` runs `src/core.ts` via node type stripping (`node --experimental-strip-types --test`? — use a plain assert script, simpler exit code contract; the runner imports `./src/core.ts`). Harness: `dispatch(model, msg)` returns the model; when `update` returns `[model, cmd]`, record the command (name/payload/ok-arm/err-arm) and give the test a `hostAnswer(resultMsg)` helper; `assertModel`/`assertCmd` helpers with byte comparisons. Oracles (the sequence covers the objective's smoke):

  - `create unlocks`: fresh → `create_attempt(pw)` → one `Cmd.request("vault.create")` with frame `[1][len][pw]`; answer `created` → phase `"unlocked"`, payload `[]`.
  - `save then lock then unlock restores payload`: unlocked → `save_attempt(payload)` → request `vault.save` framed `[1][len][payload]`; answer `saved`; `lock` → `Cmd.host("vault.lock")` + phase `"locked"` + payload cleared; `unlock_attempt(pw)` → request `vault.unlock`; answer `unlocked(payload)` → payload restored byte-identical.
  - `wrong password keeps locked`: unlock_attempt → answer `unlock_failed("wrong_password")` → phase stays `"locked"`, `error` == `"wrong_password"`.
  - `change password keeps session`: unlocked → `change_attempt(cur, next)` → request framed with 2 fields; answer `changed` → phase stays `"unlocked"`.
  - `save while locked issues no command`: locked → `save_attempt` → no Cmd, error `"locked"`.
  - `change while locked issues no command`: locked → `change_attempt` → no Cmd.
  - `lock is idempotent`: `lock` from `"locked"` issues no duplicate host call and stays locked.
  - `password never enters the model`: after `create_attempt`, assert no model field contains the password bytes (sweep the model for the byte sequence); after `change_attempt`, same for both passwords.

  Expected: FAIL (core is still the Task 1 ping-only core).

- [ ] **Step 2: Implement the full core** (`src/core.ts`) — `Phase`, `Model`, `Msg`, `viewUnbound`, frame builder (locally-owned scratch arrays; u32be writes via shift/or), guards per "Locked protocols", byte-compare helpers for error codes. Keep `ping_*` arms (harmless, used later) or drop them if the node harness does not need them — drop to keep the surface minimal (the wiring's `vault.ping` Test-1 round-trip test then uses `unlock_attempt`… no — keep `ping_attempt`; it is the round-trip smoke seam and costs one arm).

- [ ] **Step 3: Green** — `node --experimental-strip-types tests/core-logic.test.mjs` exits 0; then `nix-shell --run "native check"` (subset checker must accept the whole file — fix NS diagnostics it names); `npx tsc --noEmit` clean.

- [ ] **Step 4: Simulation pass (state-machine layer)** — extend the harness with a scripted Monte-Carlo-ish sweep: a seeded pseudo-random op sequence (create/unlock/save/lock/change/attempts) over 200 steps, asserting the invariants after every step: (a) `phase ∈ {fresh, locked, unlocked}`; (b) `phase == "unlocked"` iff the last successful op was create/unlock/change and no lock since; (c) every issued `vault.save` was preceded by `phase == "unlocked"`; (d) error bytes only ever hold one of the known codes; (e) after every `lock`, payload is empty. The harness records every violating sequence and prints it.

- [ ] **Step 5: Gate script + seen failing** — `tools/gates/gate-ts.sh`: `set -euo pipefail`; runs `npx tsc --noEmit`, `node --experimental-strip-types tests/core-logic.test.mjs`. Break the `lock` guard once → gate fails → revert.

- [ ] **Step 6: Commit** — `git-safe-commit "feat: vault session state machine in TS core"`.

---

## Task 5: Full-loop round-trip, smoke, gates, CI, ledger

**Files:**
- Create: `tools/gates/gates.sh`, `tools/gates/gate-check.sh`, `tools/gates/gate-zig.sh`, `tools/smoke/run.sh`, `GATES.md`, `.scratch/kakuriyo/prove/ledger.md`, `.github/workflows/ci.yml` (extend scaffold)
- Modify: `src/app_runner/host_roundtrip_tests.zig`, `package.json`, `README.md`

**Interfaces:** everything from Tasks 1–4.

- [ ] **Step 1: Full-loop tests over the effects channel with a real vault file** (extend `host_roundtrip_tests.zig`; real executor, real crypto, real fs in a `tmpDir`):

  - `test "full smoke sequence"` — dispatch: `create_attempt(pw)` → drain → phase unlocked; `save_attempt(minimal payload)` → drain → saved; `lock` → drain → locked + model payload cleared; `unlock_attempt(pw)` → drain → payload restored byte-identical; `unlock_attempt(bad)` → drain → `unlock_failed` with `wrong_password` + phase locked; `change_attempt(cur, next)` (after a fresh unlock) → drain → changed; lock; unlock with `next` → payload restored; lock; unlock with `cur` → failed. Every step asserts the model state transition.
  - `test "file bytes prove rewrap-only change"` — after save, snapshot the file region `[108..]` (payload_nonce + payload_ct) and header region `[20..108]`; after `change_password`, re-read: header region changed, payload region byte-identical (the no-re-encrypt requirement proven at the binary level).
  - `test "save is atomic on disk"` — after 5 mixed saves, the vault file always passes a loaded header check, the tmp dir has no leftover temp/hex files, and `unlock` yields the last payload.
  - `test "locked save is rejected end-to-end"` — locked → `save_attempt` → NO `vault.save` request issued by the core (guard) and file bytes unchanged.
  - `test "unknown request is rejected"` — call `effects.hostRequest` directly with `name = "vault.nope"` (build the wire record the TS core would) → the err route fires with `unknown` bytes and the app does not crash; then the model still accepts a normal dispatch.

  These tests replace/extend the Task 1 ping test (keep ping as the seam smoke).

- [x] **Step 2: Smoke runner** — `tools/smoke/run.sh`: (1) `zig build test-vault`; (2) full `zig build test` (round-trip suite); (3) node core harness; (4) file-level assertion script (bash + `od`/`xxd`) that after a scripted save+change run checks the vault header bounds (magic `KAKU` at offset 0; version 1 at offset 4) — the run script performs the file ops via the test binary's temp dir only (no UI). Prints PASS lines per objective item (create/Unlock/save/Lock/re-Unlock/read; wrong password; rewrap-without-re-encrypt). Exit non-zero on any failure.

- [x] **Step 3: One-command gate set** — `tools/gates/gates.sh` runs, in order, with banners and non-zero propagation: `gate-check.sh` (`native check --strict`), `gate-ts.sh`, `gate-vault.sh` (`zig build test-vault`), `gate-zig.sh` (`zig fmt --check src build build.zig src/**/*.zig` + `zig build test --summary all`), `gate-mutate.sh`, `tools/smoke/run.sh`. `package.json` `"gate": "tools/gates/gates.sh"`.

- [x] **Step 4: Every gate seen failing** — for each script, break the thing it checks once (a stray byte in app.zon / an unformatted file / a disabled guard in the core / a reverted mutant expectation / a wrong assertion in the smoke), record `exit != 0`, revert.

- [x] **Step 5: GATES.md + CI** — write `GATES.md` (use the writing-for-agents skill: load `~/.agents/skills/writing-for-agents/SKILL.md` before drafting); document each gate, the rule it encodes, its command, and the mutant list with dispositions. Extend `.github/workflows/ci.yml` so CI runs the SAME `tools/gates/gates.sh` (ubuntu-latest, `sudo apt-get install -y libgtk-4-dev pkg-config`, Node 24 via actions/setup-node, zig installed by the native CLI with `--yes` — mirror the `--full` scaffold's CI content adapted to install gtk4 and call the gate script).

- [x] **Step 6: Ledger** — `.scratch/kakuriyo/prove/ledger.md`: the prove step-7 table (surface | tier | layers | coverage | mutation score | gates | skipped layers + why), plus the adversarial-pass write-up (what was hunted: torn saves, duplicate answers, nonce reuse, key-mixups, lock-path double-free, password length edges) and any survivors annotated with equivalence reasons. The ledger must name the riskiest unproven thing (candidate: real-window UI path — out of scope; and arg: password buffers in TS arena memory — best-effort per threat model).

- [x] **Step 7: Commit** — `git-safe-commit "test: full-loop vault round-trip, smoke, mutation gates, ledger"` (split docs into a second commit if cleaner).

---

## Task 6: Completion audit

- [x] **Step 1: Fresh-clone gate run** — from a clean checkout (stash/`git worktree` or re-clone to /tmp): `nix-shell --run "npm run gate"` green end-to-end, plus `native build` (ReleaseFast binary) and `native check --strict`.
- [x] **Step 2: Objective checklist mapping** — DONE WHEN evidence: (1) scaffold+eject — `d122e76` (`build.zig`, `build/kak_app.zig`, `ts_core_main.zig`, README loop); (2) `vault.*`/`bindHostCalls` — `host_roundtrip_tests.zig` + `vault_host.zig` green via `gate-ts`/`test-vault` (`979220a`); binding-level only, TS routed cycle blocked per `ts-core-lane-limits.md`; (3) envelope closed — `vault.zig` 29 tests + 8/8 mutants (`4703a93`); (4) smoke — `smoke.zig` 8 PASS lines + `tools/smoke/run.sh` (`364fbc4`); (5) /prove — ledger at `.scratch/kakuriyo/prove/ledger.md`, `gates.sh` non-zero, CI mirrors local (`9c924e4`/`462de7d`), oracle order `d122e76` binding before `4703a93` crypto.
- [x] **Step 3: Report + push** — vault v1 DONE WHEN met; pushed `d122e76..33790e1` to `origin/main` (user approved); `main` synced at `33790e1`.