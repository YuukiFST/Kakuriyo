# Research: GPUI viability for Kakuriyo

**Question:** Can gpui (and optionally longbridge/gpui-component) support Kakuriyo as a standalone desktop vault on Windows 11 and Linux (NixOS priority): keyboard-first navigation, dark UI, nested list + detail/Preview image panel, local file I/O, standalone executable, zero telemetry?

**Verdict: go-with-caveats**

No hard capability blockers for Kakuriyo’s stated needs. Primary risks are pre-1.0 churn, thin external docs, and packaging/system deps on Linux (especially NixOS). Prefer pinning git (or a known crates.io cut) of `gpui` + `gpui_platform`, and strongly consider `gpui-component` for Tree / Dock / Theme.

---

## Sources (primary only)

| Source | URL |
| --- | --- |
| GPUI homepage | https://gpui.rs |
| GPUI crate README (current) | https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md |
| GPUI crate on crates.io | https://crates.io/crates/gpui |
| GPUI crate root / Cargo.toml | https://github.com/zed-industries/zed/blob/main/crates/gpui/Cargo.toml |
| Key dispatch docs | https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/key_dispatch.md |
| Contexts docs | https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/contexts.md |
| Image example | https://github.com/zed-industries/zed/blob/main/crates/gpui/examples/image/image.rs |
| Uniform list example | https://github.com/zed-industries/zed/blob/main/crates/gpui/examples/uniform_list.rs |
| gpui_platform Cargo.toml | https://github.com/zed-industries/zed/blob/main/crates/gpui_platform/Cargo.toml |
| Building Zed for Linux | https://zed.dev/docs/development/linux.html (source: https://github.com/zed-industries/zed/blob/main/docs/src/development/linux.md) |
| Linux deps script | https://github.com/zed-industries/zed/blob/main/script/linux |
| Zed telemetry (editor, not GPUI) | https://zed.dev/docs/telemetry |
| gpui-component README | https://github.com/longbridge/gpui-component/blob/main/README.md |
| gpui-component crates.io | https://crates.io/crates/gpui-component |
| gpui-component docs (tree, theme, dock) | https://docs.rs/gpui-component/ |
| ThemeMode source | https://docs.rs/gpui-component/latest/src/gpui_component/theme/mod.rs.html |
| egui README (fallback) | https://github.com/emilk/egui/blob/master/README.md |
| Tauri start docs (fallback) | https://tauri.app/start/ |
| Kakuriyo product context | `Kakuriyo/CONTEXT.md` / map Destination |

---

## Requirement matrix

| Kakuriyo need | Supported? | Evidence |
| --- | --- | --- |
| Standalone desktop app (not embedded in Zed) | **Yes** | `gpui_platform::application().run(...)` + `App::open_window` ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md); [gpui.rs](https://gpui.rs)) |
| Windows 11 | **Yes (documented)** | README: Windows uses Win32 + DirectWrite; no platform features required ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)). `gpui_platform` depends on `gpui_windows` on Windows ([Cargo.toml](https://github.com/zed-industries/zed/blob/main/crates/gpui_platform/Cargo.toml)). |
| Linux / NixOS priority | **Yes, with packaging work** | Linux: enable `wayland` and/or `x11` on `gpui_platform` ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)). Zed docs: X11 and Wayland supported ([linux.md](https://github.com/zed-industries/zed/blob/main/docs/src/development/linux.md)). Official `script/linux` lists system libs but **does not include NixOS** ([script/linux](https://github.com/zed-industries/zed/blob/main/script/linux)) — NixOS must map those deps into a flake/derivation. |
| Keyboard-first navigation | **Yes (first-class)** | “GPUI is designed for keyboard-first interactivity.” Actions + `key_context` + keymap JSON ([key_dispatch.md](https://github.com/zed-industries/zed/blob/main/crates/gpui/docs/key_dispatch.md)). |
| Dark UI | **Yes** | Arbitrary colors via Tailwind-style styling on `div` ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md); hello world uses dark greys on [gpui.rs](https://gpui.rs)). With gpui-component: `ThemeMode::{Light, Dark}`, `Theme::change`, light/dark theme configs ([ThemeMode](https://docs.rs/gpui-component/latest/gpui_component/theme/enum.ThemeMode.html); [theme mod](https://docs.rs/gpui-component/latest/src/gpui_component/theme/mod.rs.html)). |
| Nested Collections list | **Yes** | gpui-component `Tree` / `TreeItem` / `TreeState` ([docs](https://docs.rs/gpui-component/latest/gpui_component/tree/index.html)). Core GPUI also has `uniform_list` for virtualized flat lists ([example](https://github.com/zed-industries/zed/blob/main/crates/gpui/examples/uniform_list.rs)). |
| Detail / Preview image panel | **Yes** | Layout: flex/`div` (core) or Dock panels / resizable layouts (gpui-component [dock](https://docs.rs/gpui-component/latest/gpui_component/dock/index.html), README “Dock layout”). Images: `img(...)` from local path, remote URI, or assets ([image example](https://github.com/zed-industries/zed/blob/main/crates/gpui/examples/image/image.rs)); `image` crate dependency in GPUI ([Cargo.toml](https://github.com/zed-industries/zed/blob/main/crates/gpui/Cargo.toml)). |
| Local file I/O (Vault at rest, export/import) | **Yes (orthogonal)** | Normal Rust `std::fs` / async I/O. GPUI examples load assets via `fs::read` in `AssetSource` ([image example](https://github.com/zed-industries/zed/blob/main/crates/gpui/examples/image/image.rs)). Encryption/Vault is app logic, not a GPUI concern. |
| Standalone executable | **Yes** | Native Rust GUI binary. gpui-component reports ~12MB min release hello-world binary size ([README comparison table](https://github.com/longbridge/gpui-component/blob/main/README.md)). |
| No telemetry | **Yes for a Kakuriyo app** | Telemetry is documented for the **Zed editor** (opt-out client metrics/diagnostics) ([zed.dev/docs/telemetry](https://zed.dev/docs/telemetry)). GPUI README/API describe UI framework concerns only — no phone-home API in framework docs ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)). Shipping Kakuriyo without Zed’s `telemetry` / `crashes` crates keeps the app offline-silent unless *you* add telemetry. |

---

## Stack shape that matches official guidance

Current upstream Getting Started (git `main`):

```toml
gpui = { version = "*" }
gpui_platform = { version = "*", features = ["font-kit", "wayland", "x11"] }
```

Windows: no `gpui_platform` features required. Linux: at least one of `wayland` / `x11`. ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md))

gpui-component officially recommends **git** deps for `gpui`, `gpui_platform`, and itself ([README](https://github.com/longbridge/gpui-component/blob/main/README.md)):

```toml
gpui = { git = "https://github.com/zed-industries/zed" }
gpui_platform = { git = "https://github.com/zed-industries/zed", features = ["font-kit"] }
gpui-component = { git = "https://github.com/longbridge/gpui-component" }
```

**crates.io note:** `gpui` is published (0.2.2 as of crates.io page, Apache-2.0) ([crates.io/crates/gpui](https://crates.io/crates/gpui)). The **crates.io README text is stale** relative to git (still describes “macOS or Linux” in the published crate description snapshot); **trust the git README for Windows**. `gpui_platform` exists on git (`publish.workspace = true`, v0.1.0) ([Cargo.toml](https://github.com/zed-industries/zed/blob/main/crates/gpui_platform/Cargo.toml)); crates.io API for `gpui_platform` was not found at research time — plan on git or verify publish status before locking a crates-only path. `gpui-component` is on crates.io (0.5.1) but its README still points consumers at git Zed crates ([crates.io](https://crates.io/crates/gpui-component)).

License: GPUI Apache-2.0 ([crates.io](https://crates.io/crates/gpui)); gpui-component Apache-2.0 ([README](https://github.com/longbridge/gpui-component/blob/main/README.md)).

---

## Hard blockers

**None identified** against Kakuriyo’s listed requirements (Win11 + Linux, keyboard-first, dark UI, nested list + preview image, local I/O, standalone binary, no telemetry).

Non-blockers often mistaken for blockers:

- Zed’s own telemetry ≠ GPUI shipping telemetry ([telemetry docs](https://zed.dev/docs/telemetry)).
- Sparse docs ≠ missing APIs; official stance is “read Zed source / Discord” while docs improve ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md); [gpui.rs](https://gpui.rs)).

---

## Maturity risks (real)

1. **Pre-1.0 / breaking changes** — Explicit: “still pre-1.0. There will often be breaking changes between versions” ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)).
2. **Tied to Zed** — Contributions must stay in sync with Zed; framework evolution follows editor needs ([gpui.rs](https://gpui.rs) “Contributing to gpui”).
3. **Docs lag** — Best learning path is Zed crates / Discord ([README](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)).
4. **Dependency / publish skew** — `gpui` vs `gpui_platform` vs `gpui-component` versions may drift; git pins are the officially shown path for components ([gpui-component README](https://github.com/longbridge/gpui-component/blob/main/README.md)).
5. **Linux / NixOS packaging** — Need Vulkan/graphics, Wayland/X11, fontconfig, etc. (see Zed’s `script/linux` package lists). NixOS is unsupported by that script → first-class flake work is on Kakuriyo ([script/linux](https://github.com/zed-industries/zed/blob/main/script/linux)).
6. **Windows maturity vs macOS** — Windows is documented and wired (`gpui_windows`), but Zed’s historical center of gravity was macOS; treat Win11 as “supported, smoke-test early” rather than “proven for every widget.”

---

## Recommended approach for Kakuriyo

1. **Adopt GPUI + gpui-component** for Tree, Theme (`Dark`), Dock/split, List/VirtualList, forms/dialogs.
2. **Pin git revs** (or a verified crates cut) for `gpui` / `gpui_platform` / `gpui-component` together.
3. **Prototype early on NixOS + Win11**: window open, keymap navigation, Tree + detail `img`, file read/write of a dummy Vault file.
4. **Do not** depend on Zed app crates that implement telemetry/AI/collaboration.

---

## Honest fallbacks (if GPUI becomes painful)

Use these if churn, docs, or Nix packaging cost outweigh GPUI’s look/keyboard model — not because GPUI cannot meet the requirements on paper.

### egui + eframe

- Pure Rust immediate-mode GUI; official `eframe` targets Web, Linux, Mac, Windows ([egui README](https://github.com/emilk/egui/blob/master/README.md)).
- Dark/light themes, images, panels, keyboard input; mature ecosystem.
- Tradeoff: “not native looking”; still breaking changes in active development ([egui README State](https://github.com/emilk/egui/blob/master/README.md)).
- Fits offline/local/no-telemetry vaults well; weaker “Zed-class” desktop chrome than GPUI + gpui-component.

### Tauri 2

- Rust backend + web frontend; ships small binaries using system webview ([tauri.app/start](https://tauri.app/start/)).
- Strong distribution story on Win + Linux; file I/O via Rust.
- Tradeoff: UI is web tech (not GPUI’s GPU Rust UI); keyboard-first and dark vault UX are doable but different stack; not pure-Rust UI.

### Ranking for Kakuriyo preferences

| Priority | Prefer |
| --- | --- |
| Visual/keyboard affinity with modern GPU Rust UI | **GPUI (+ gpui-component)** |
| Lower framework churn / more community examples | **egui** |
| Fastest path to polished installers + web UI skill reuse | **Tauri** |

---

## Decision

**go-with-caveats:** Use GPUI (with gpui-component) for Kakuriyo. Capability fit is good; accept pre-1.0 churn, git pinning, and NixOS packaging as project costs. Fall back to egui if GPUI velocity/docs block progress; use Tauri only if a web UI becomes acceptable.
