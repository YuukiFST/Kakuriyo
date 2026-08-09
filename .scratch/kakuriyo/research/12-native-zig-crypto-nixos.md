# Research: Native SDK Zig crypto + NixOS smoke

**Ticket:** [issues/27](https://github.com/YuukiFST/Kakuriyo/issues/27)  
**Question:** With Native SDK + **TypeScript** core: can Kakuriyo implement the closed Vault crypto design (Argon2id KEK + random DEK + XChaCha20-Poly1305, secrecy/zeroize discipline) in **Zig** under the TS core, and can a minimal Native app be built/packaged on **NixOS** while still targeting Win11?  
**Sources:** primary docs only (Native SDK, Zig std, CONTRIBUTING / packaging).

---

## Verdict

**Go with caveats.** Zig’s standard library already provides the locked primitives (`argon2id` KDF + `XChaCha20Poly1305` AEAD + CSPRNG + `secureZero`). Calling that from a TypeScript core is a first-class effects seam (`Cmd.request` / `Cmd.host` → Zig `hostRequest` / `hostSend` with a bound host handler), not inventing FFI. A minimal native-only Linux app can be built and packaged with the official Linux install-tree path; NixOS has **no first-party flake**, so packaging is DIY around GTK4 + Zig 0.16 + Node (for the TS toolchain). Windows remains a real (early) packaging target. No hard algorithm or platform blocker; the soft costs are **ejecting/owning build wiring** to bind Zig vault services, and **NixOS dependency wrapping**.

---

## Sources (primary)

| Source | URL |
| --- | --- |
| Native SDK homepage / principles | https://native-sdk.dev |
| TypeScript cores (effects, subset, host Cmds) | https://native-sdk.dev/docs/typescript |
| Where packages go (no npm in core) | https://native-sdk.dev/docs/typescript/packages |
| App model / Zig vs TS | https://native-sdk.dev/docs/app-model |
| Packaging (linux / windows / macos) | https://native-sdk.dev/docs/packaging |
| Platform support | https://native-sdk.dev/docs/platform-support |
| Quick start (Zig 0.16, CLI toolchain) | https://native-sdk.dev/docs/quick-start |
| Zig 0.16 notes | https://native-sdk.dev/docs/zig |
| Extensions / ModuleRegistry | https://native-sdk.dev/docs/extensions |
| native doctor | https://native-sdk.dev/docs/debugging/doctor |
| Package distribution (npm + musl/glibc) | https://native-sdk.dev/docs/packages |
| Native README / CONTRIBUTING (Linux GTK4) | https://github.com/vercel-labs/native |
| linux-truth (GTK4, Xvfb verification) | https://github.com/vercel-labs/native/tree/main/tools/linux-truth |
| Effects host binding (`bindHostCalls`) | `src/runtime/effects.zig`, `src/runtime/effects_host_tests.zig` |
| TS core host wire (`Cmd.request` → `fx.hostRequest`) | `src/runtime/ts_core_host.zig` |
| Zig `std.crypto` Argon2 | https://github.com/ziglang/zig/blob/master/lib/std/crypto/argon2.zig |
| Zig `std.crypto` ChaCha / XChaCha-Poly1305 | https://github.com/ziglang/zig/blob/master/lib/std/crypto/chacha20.zig |
| Zig `std.crypto` root (`aead`, `pwhash`, `random`, `secureZero`) | https://github.com/ziglang/zig/blob/master/lib/std/crypto.zig |
| Prior Vault algorithms (locked) | `.scratch/kakuriyo/research/03-encrypted-vault-at-rest.md` · closed #3 |
| Stack decision | closed #26 (Native + TS core; crypto in Zig) |
| Prior Native vs GPUI | `.scratch/kakuriyo/research/11-native-sdk-vs-gpui.md` |

---

## Requirement matrix

| Need | Status | Notes |
| --- | --- | --- |
| Argon2id KEK derivation in Zig | **Yes (std)** | `std.crypto.pwhash.argon2.kdf(..., .argon2id)`; `Params.owasp_2id` = `{ .t = 2, .m = 19 * 1024, .p = 1 }` — same OWASP baseline as research #3 |
| Random DEK + salts/nonces (CSPRNG) | **Yes (std)** | `std.crypto.random` (thread-local CSPRNG over OS entropy) |
| XChaCha20-Poly1305 AEAD | **Yes (std)** | `std.crypto.aead.chacha_poly.XChaCha20Poly1305` — 32-byte key, 24-byte nonce, 16-byte tag; `encrypt` / `decrypt` |
| Secrecy / wipe-on-lock discipline | **Yes (std, manual)** | No Rust `secrecy`/`zeroize` crates; use `std.crypto.secureZero` + drop unlocked session state. Same threat-model honesty as #3 (best-effort wipe, not anti-DMA) |
| Third-party Zig crypto crates | **Not required** | Prefer std only for the locked algorithms; avoid inventing modes |
| Call Zig crypto from TS core | **Yes, with wiring** | `Cmd.request(name, payload, { key?, ok, err })` / `Cmd.host`; engine maps to `fx.hostRequest` / `fx.hostSend`; answer via `Effects.bindHostCalls` (`request_fn` + `feedHostResult`). Unbound requests reject on the err route |
| Crypto inside pure TS subset | **No (don’t)** | Cores forbid npm; no JS engine in the binary. Vendoring Argon2 in subset TS is possible but wrong — keep crypto in Zig |
| Persist vault file | **Yes** | `Cmd.readFile` / `Cmd.writeFile` (or Zig `fx.readFile` / `fx.writeFile`); boot load + atomic replace remain app protocol |
| Build minimal app on Linux | **Yes** | GTK software renderer path; CI/`linux-truth` exercises real windows under Xvfb. Native-only builds stub WebKitGTK (`NATIVE_SDK_ALLOW_WEBKITGTK_STUB`) |
| Package on Linux | **Yes** | `native package --target linux` → `bin/`, `.desktop`, hicolor icons, optional MIME |
| NixOS first-party packaging | **No** | No flake/`shell.nix` in `vercel-labs/native`. DIY: Zig 0.16 (CLI download or nixpkgs), Node 22.15+, GTK4 (+ WebKitGTK only if WebView), wrap binary for Nix store libs |
| Target Win11 | **Yes, early** | Win32 host; packaging = distributable directory (+ optional HKCU file-type script). CI includes Windows truth / Wine paths |
| Linux tray | **Unsupported** | Returns `UnsupportedService` — not a Vault crypto blocker |
| Pre-1.0 churn | **Accept** | Explicit pre-1.0; same class of risk already accepted in #26 |

---

## Zig crypto mapping (locked design → std)

| Role (from #3) | Zig std API | Notes |
| --- | --- | --- |
| KDF | `std.crypto.pwhash.argon2.kdf(allocator, derived_key, password, salt, params, .argon2id)` | Needs allocator for working memory; salt ≥ 8 bytes per API; store `t/m/p` beside salt |
| KDF params baseline | `Params.owasp_2id` | Matches OWASP / prior Rust `argon2::Params::DEFAULT` |
| Desktop tuning | `interactive_2id` / `moderate_2id` / `sensitive_2id` | Raise memory/time if Unlock UX allows; persist params |
| AEAD | `std.crypto.aead.chacha_poly.XChaCha20Poly1305` | Prefer XChaCha over IETF ChaCha20-Poly1305 for random nonces |
| RNG | `std.crypto.random.bytes(&buf)` (via `std.Random`) | DEK, salt, nonces |
| Wipe | `std.crypto.secureZero(u8, slice)` | Call on KEK/DEK/password buffers on Lock; volatile sink to resist elision |
| Optional backup | Vault file copy; or `age` later | age passphrase path stays scrypt (interop only) — unchanged from #3 |

**Envelope flow (unchanged algorithmically):** CSPRNG DEK → Argon2id(password, salt, params) → KEK → wrap DEK under XChaCha → encrypt vault under DEK → persist versioned header + ciphertext. Unlock / password-change / Auto-lock semantics from #3 still apply; only the implementation language moves.

---

## How TS cores reach Zig (not a free “FFI import”)

Native’s two-tier rule:

1. **App core (TS):** pure `Model`/`Msg`/`update`; effects are inert `Cmd` data.
2. **Toolkit / host services (Zig):** custom widgets, host services, crypto engines.

Documented vocabulary:

| TS | Zig engine | Use for Vault |
| --- | --- | --- |
| `Cmd.request(name, payload, { key, ok, err })` | `fx.hostRequest` + bound `request_fn` | Unlock, wrap, encrypt/decrypt round-trips that return bytes |
| `Cmd.host(name, …)` / host_bytes | `fx.hostSend` | Fire-and-forget (e.g. wipe session on host side) |
| `Cmd.readFile` / `Cmd.writeFile` | file effects | Persist ciphertext; keep plaintext out of durable model fields when locked |
| `Cmd.spawn` | subprocess | **Fallback only** — sidecar crypto is a deployment footgun |

**Recommended packaging shape for Kakuriyo crypto:**

1. Keep `src/core.ts` as UI/session orchestration (locked/unlocked flags, paths, Msgs).
2. Implement `vault.zig` (or `src/vault/`) with std crypto only — unit-testable without the UI.
3. **`native eject` or `native init --full`** so you own `build.zig` / runner wiring and can `bindHostCalls` that dispatch `vault.*` names and `feedHostResult`.
4. Never put Master Password or DEK into long-lived Model fields as ordinary bytes without a clear lock path that zeros host-side buffers.

**Honest fallbacks (ordered):**

| Fallback | When | Cost |
| --- | --- | --- |
| **A. Recommended:** TS core + Zig vault host service | Default after #26 | Must own ejected build; host binding is tested in SDK but app-authored |
| **B. Zig-core for the whole app** (`--template zig-core`) | If host binding / eject churn hurts more than TS DX | Abandons TS-core preference from #26 for crypto locality |
| **C. `Cmd.spawn` crypto helper** | Temporary spike only | Extra binary, argv/protocol, worse audit surface — do not ship |
| **D. Pure TS Argon2 in subset** | Never | Wrong place; slow to write; duplicates std |

There is **no** documented zero-config “drop a `.zig` file next to `core.ts` and import it.” Host services are Zig-side bindings. That is a process caveat, not an algorithm blocker.

---

## NixOS / Linux / Windows reality

### Linux (including NixOS as a consumer)

- **Renderer:** software via GTK host; verified by `tools/linux-truth` (GTK4 + Xvfb container).
- **Native-only apps:** do not link WebKitGTK; CONTRIBUTING still lists GTK4 (+ WebKitGTK for WebView work). Kakuriyo Destination = native-only → GTK4 is the hard Linux dep, not WebKit.
- **Package:** `native package --target linux` install tree (`bin/`, `share/applications/`, icons).
- **CLI:** `@native-sdk/cli-linux-*-gnu` and `*-musl` artifacts exist — helpful on Nix if you prefer musl static-ish tooling, but **the app binary still links GTK** dynamically for the host.

**NixOS smoke (what “works” means here):**

| Step | Expectation |
| --- | --- |
| Install CLI | npm global or nix-wrapped Node + `@native-sdk/cli`; Zig 0.16 via CLI `~/.native/toolchains/` or nixpkgs |
| `native init` / `native doctor` | Doctor checks platform + optional WebView; native-only may warn on WebKit — non-fatal if unused |
| `native build` | Needs GTK4 headers/libs visible to Zig/pkg-config (`gtk4` in a `mkShell` / `buildFHSEnv`) |
| Run binary | NixOS: wrap with `wrapGAppsHook` / `LD_LIBRARY_PATH` / `buildFHSEnv` so GTK finds schemas and shared libs |
| `native package --target linux` | Emits install tree; package into a Nix derivation that installs that tree and wraps the binary |

**Not a hard blocker:** absence of upstream flake. **Is a soft blocker:** first NixOS derivation is app-owned research → engineering, not “npm install and forget.”

### Windows 11

- Real Win32 host; Direct2D with software fallback; IME mapped.
- Packaging early: directory artifact + optional per-user file-type registration script.
- Cross-compile / Wine paths exist in upstream CI — ship Win11 from a Linux/NixOS **dev** machine is plausible for smoke, with final validation on real Windows still wise.

### Cross-cutting platform caveats (already known from #11)

- macOS remains upstream’s deepest platform; Kakuriyo’s Win11+NixOS priority is **supported but secondary**.
- Linux tray unsupported.
- Pre-1.0 API churn.

---

## Hard blockers vs soft costs

| Class | Item |
| --- | --- |
| **Hard blockers** | **None** for the locked crypto algorithms or for “can a minimal Native app exist on Linux/Win11.” |
| Soft — crypto wiring | Must eject/own Zig host binding (or switch to Zig-core) to call vault from TS |
| Soft — memory discipline | Reimplement secrecy/`ZeroizeOnDrop` patterns with `secureZero` + session drop; no crate port |
| Soft — NixOS | DIY GTK wrap + Zig 0.16 pin; no upstream Nix docs |
| Soft — maturity | Pre-1.0 Native; Windows packaging early; Linux software renderer / no tray |
| Soft — Argon2 perf | `kdf` allocates working memory; Unlock may take 1–5s at tuned params — product UX, not a no-go |

---

## Recommendation

1. **Proceed** with Zig **std-only** vault crypto matching #3’s envelope (Argon2id + XChaCha20-Poly1305 + `secureZero`).
2. Keep **TypeScript** as the UI/session core; put crypto behind **`Cmd.request` host services** implemented in Zig after **`native eject` / `--full`**.
3. Treat **NixOS packaging** as an early spike ticket: `mkShell` with GTK4 + Node + Zig → `native build` → wrap → `native package --target linux`, then a thin Nix derivation. Parallel Win11 package smoke on CI or a Windows box.
4. Do **not** use npm crypto, spawn sidecars, or rewrite algorithms. Optional `.age` backup stays as in #3 (interop), not the primary vault format.

**Next engineering tickets (suggested, not opened here):** vault Zig module + host binding prototype; NixOS `native build` smoke derivation; Windows package smoke.

---

## Implementation checklist (for a later build session)

1. Scaffold TS Native app; eject when adding `vault.zig`.
2. Implement create/unlock/save/password-change/lock using std crypto + `secureZero`.
3. Bind `vault.unlock` / `vault.encrypt` / … via `bindHostCalls`; wire `Cmd.request` from `core.ts`.
4. Persist with `Cmd.writeFile` (atomic temp→rename at host or app layer).
5. NixOS: shell with `gtk4`, pkg-config, Zig 0.16, Node → build → wrap → package.
6. Win11: `native package --target windows` smoke; run on real hardware before release claims.
