# Research: Native SDK (vercel-labs/native) vs GPUI for Kakuriyo

**Question:** Is switching Kakuriyo’s UI stack from **gpui** to **[Native SDK](https://github.com/vercel-labs/native)** (`vercel-labs/native`) worth it given Destination constraints (Win11 + NixOS, keyboard-first vault, offline encrypted Vault, zero telemetry)?

**Verdict: keep gpui unless authoring/agent-loop outweighs crypto + platform maturity trade-offs**

Native SDK is a strong pre-1.0 desktop toolkit (Zig engine; TypeScript or Zig cores; `.native` markup; no WebView required). It fits Kakuriyo’s *shape* (notes/tree/split chrome, dark tokens, small binary, tray/dialogs/clipboard). It does **not** clearly beat gpui on Kakuriyo’s *hard* constraints: **NixOS-first Linux**, **already-chosen Rust crypto stack**, and **keyboard-first IDE chrome** already researched for GPUI. Switching reopens [gpui viability for Kakuriyo](https://github.com/YuukiFST/Kakuriyo/issues/1) and largely invalidates language assumptions behind [Encrypted Vault at rest](https://github.com/YuukiFST/Kakuriyo/issues/3).

---

## Sources (primary)

| Source | URL |
| --- | --- |
| Native SDK README | https://github.com/vercel-labs/native/blob/main/README.md |
| Native SDK homepage | https://native-sdk.dev |
| Platform support | https://native-sdk.dev/docs/platform-support |
| Capabilities | https://native-sdk.dev/docs/capabilities |
| Repo metadata | `gh api repos/vercel-labs/native` (Apache-2.0, lang Zig, created 2026-05-08) |
| Prior Kakuriyo GPUI research | `.scratch/kakuriyo/research/01-gpui-viability.md` |
| Encrypted Vault decision | https://github.com/YuukiFST/Kakuriyo/issues/3 |

---

## What Native SDK is

- **Engine:** Zig-owned pixel renderer into real OS windows — **no browser / no WebView / no JS runtime in release binaries** (TS cores compile to native at build time).
- **Authoring:** `.native` declarative markup + `Model`/`Msg`/`update` in TypeScript (default) or Zig (`--template zig-core`).
- **Maturity:** Explicitly **pre-1.0**; APIs still move ([README Contributing](https://github.com/vercel-labs/native/blob/main/README.md)).
- **License:** Apache-2.0.
- **Examples relevant to Kakuriyo:** `notes` (three-pane folders/list/editor + persistence), `feed` (virtualized lists), tree component docs, keyboard-shortcuts docs, tray/dialogs/clipboard capabilities.

---

## Requirement matrix (Kakuriyo)

| Need | Native SDK | Notes |
| --- | --- | --- |
| Standalone desktop, no telemetry phone-home | **Yes** | Native-only builds shed web stack; no framework telemetry documented as required. |
| Windows 11 | **Yes, with caveats** | Win32 host; Direct2D/DirectWrite with software fallback; CI includes Windows truth + Wine paths. macOS remains **primary** platform. |
| Linux / **NixOS priority** | **Works, weaker than macOS** | Linux = **software renderer** via GTK path; full showcase exercised under Xvfb. Tray on Linux returns `UnsupportedService` today. NixOS packaging = Zig + GTK deps (not first-party Nix docs). |
| Keyboard-first / Vim Motion | **Plausible** | Keyboard + IME on all desktops; dedicated keyboard-shortcuts docs. Not GPUI’s Action/keymap depth proven for Kakuriyo’s Vim Motion set — needs a prototype ticket if chosen. |
| Dark / TRUE BLACK UI | **Yes** | Design tokens / theme replace wholesale (`soundboard` vs `deck`). |
| Nested Collections tree + IDE split | **Yes (shape fit)** | Tree component; `notes` three-pane; virtual lists. |
| Preview images | **Yes** | Image registration / decoded covers in examples; GPU/software backends per host. |
| Local Vault file I/O + export/import | **Yes (effects)** | File effects + native open/save dialogs on desktop. |
| Encrypted at rest (Argon2id + XChaCha20-Poly1305) | **Rewrite required** | Decision assumed **Rust** crates (`argon2`, `chacha20poly1305`, `secrecy`/`zeroize`). Native cores are **Zig or TS→native** — Rust crypto research does not drop in. Zig has crypto; must re-validate. |
| Master Password Unlock (no OS keyring required) | **Yes** | OS credentials API exists but Kakuriyo Unlock is app-owned Master Password (already decided). |
| Tray (fog / later) | **Partial** | macOS + Windows yes; **Linux tray unsupported** today — worse than “fog” if Linux tray becomes required. |
| $0 offline ops | **Yes** | No paid backend; Preview fetch still app-owned. |

---

## GPUI (status quo) vs Native (candidate)

| Dimension | GPUI (+ gpui-component) | Native SDK |
| --- | --- | --- |
| Language / crypto continuity | Rust — matches Vault research | Zig/TS — reopens crypto implementation language |
| Platform priority match | Zed/Linux packaging hard but Win+Linux first-class for Kakuriyo’s researched path | **macOS deepest**; Linux software; Windows real but secondary |
| Pre-1.0 churn | High (Zed git pin) | High (explicit pre-1.0) |
| Authoring / AI agents | Rust UI code; thinner agent story | First-class agent skills, automation server, `.native` + typed `update` |
| Binary size | ~12MB hello (gpui-component claim) | Few MB examples (3–6MB claimed) |
| Layout / Notes-like UX | Tree + Dock researched | Notes example + tokens closer to “shipped look” |
| Linux tray | App-dependent | **Unsupported** today |

---

## Hard reasons **not** to switch by default

1. **Invalidates closed crypto path language** — [Encrypted Vault at rest](https://github.com/YuukiFST/Kakuriyo/issues/3) is Rust-crate shaped; Native forces Zig/TS crypto story.
2. **Platform skew vs Destination** — Kakuriyo prioritizes **Win11 + NixOS**; Native prioritizes **macOS**, Linux software-rendered, Linux tray missing.
3. **Same class of pre-1.0 risk** as GPUI — switching does not buy stability.
4. **Map cost** — Reopening stack ripples Notes, keyboard prototype assumptions, handoff spec assembly.

## Hard reasons **to** switch (only if these dominate)

1. Prefer **TS/`.native` + agent automation** over Rust UI.
2. Want Notes-like chrome / token themes with less custom GPUI layout work.
3. Willing to **re-research Vault crypto in Zig** (or FFI) and accept macOS-primary maturity while developing on NixOS/Windows.

---

## Recommendation

**Do not switch yet.** Keep [gpui viability for Kakuriyo](https://github.com/YuukiFST/Kakuriyo/issues/1) as the stack decision.

If the human wants Native anyway: open a new `wayfinder:research` (Zig crypto + NixOS packaging smoke) and a `wayfinder:grilling` to formally **supersede** the GPUI decision — do not silently swap Notes/stack mid-map.
