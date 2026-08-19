# Research: GTK4 GSK on iGPU (NixOS)

**Ticket:** [How does GTK4 GSK stay on the iGPU on NixOS?](https://github.com/YuukiFST/Kakuriyo/issues/45)  
**Question:** On NixOS + Wayland, how does a GTK4 app pin GSK GPU rendering (ngl/GL and/or Vulkan) so it runs well on **integrated GPU only**, and what is the documented fallback if GSK falls back to Cairo software?  
**Sources:** GTK4 / GSK / GDK primary docs, Mesa env vars, this repo’s `shell.nix`.

---

## Verdict

GTK **does not offer a stable public API to “pin the iGPU.”** The supported path is: **do not override renderers**. `gsk_renderer_new_for_surface()` picks a GPU renderer for that surface’s display; if `GSK_RENDERER` is unset, it tries the backend default, then **Cairo as the ultimate fallback**.

On a machine whose **only** GPU is the Intel/AMD iGPU (Kakuriyo’s bar), that display GPU **is** the iGPU. Mesa’s `DRI_PRIME` exists to select a *non-default* GPU on hybrid laptops; it is not required when there is no dGPU.

**Happy path for Kakuriyo:**

1. Ship a `gtk4-rs` binary linked against NixOS `gtk4` + Mesa (same family as today’s `shell.nix`).
2. Leave `GSK_RENDERER` unset in production.
3. Never set `GSK_RENDERER=cairo`, `LIBGL_ALWAYS_SOFTWARE=true`, or `GDK_DISABLE` with `gl`/`vulkan`.
4. After realize, assert the native’s GSK renderer is **not** `GskCairoRenderer`. If it is Cairo, fail a gate (or log hard) — that is the documented software fallback, not the happy path.
5. Treat `GSK_RENDERER=gl` / `opengl` / `vulkan` as **debug-only**. GTK documents these env vars as unstable and not for end-user configuration.

Crypto and Preview stay on CPU. No CUDA/OpenCL.

---

## How GSK chooses a renderer

[`gsk_renderer_new_for_surface`](https://docs.gtk.org/gsk4/ctor.Renderer.new_for_surface.html):

> If the `GSK_RENDERER` environment variable is set, GSK will try that renderer first, before trying the backend-specific default. The ultimate fallback is the cairo renderer.

Renderer classes (GSK 4):

| Class | Role | Notes |
| --- | --- | --- |
| [`GskGLRenderer`](https://docs.gtk.org/gsk4/class.GLRenderer.html) | OpenGL scene-graph | Since 4.2 |
| [`GskVulkanRenderer`](https://docs.gtk.org/gsk4/class.VulkanRenderer.html) | Vulkan scene-graph | Realize **fails** if Vulkan is not supported |
| [`GskNglRenderer`](https://docs.gtk.org/gsk4/ctor.NglRenderer.new.html) | Alias of GL renderer | **Deprecated since 4.18**; use `gsk_gl_renderer_new()` |
| [`GskCairoRenderer`](https://docs.gtk.org/gsk4/class.CairoRenderer.html) | Software fallback | Cairo; cannot do 3D transforms |

Spec language “ngl” maps to the GL renderer after 4.18. Pinning “ngl” as a product string is stale; pin **not-Cairo** + optional `GSK_RENDERER=gl` in debug.

Inspect at runtime: [`gtk_native_get_renderer`](https://docs.gtk.org/gtk4/method.Native.get_renderer.html) on the window’s `GtkNative`, then GObject type vs `GskCairoRenderer`.

---

## Environment variables (debug, not product config)

GTK [Running and debugging](https://docs.gtk.org/gtk4/running.html):

> Environment variables are generally used for debugging purposes. They are not guaranteed to be API stable, and should not be used for end-user configuration and customization.

Relevant knobs:

### `GSK_RENDERER`

Values documented: `help`, `broadway`, `cairo`, `opengl`, `gl`, `vulkan`.

- `cairo` **is** the software path. Forbidden as Kakuriyo’s happy path.
- `gl` / `opengl` / `vulkan` force a GPU renderer **if** GTK was built with it **and** the GDK backend supports it.
- Do not ship a wrapper that always sets this; default selection is the API.

### `GSK_GPU_DISABLE` / `GSK_DEBUG`

Disable GPU-renderer optimizations (`ngl` and `vulkan`) or log fallbacks (`GSK_DEBUG=fallback`). Useful in a research/gate harness, not in `run.sh`.

### `GDK_DISABLE`

Can include `gl` and `vulkan`. Either one **pushes toward Cairo**. Do not set them.

### `GDK_BACKEND`

Wayland: `GDK_BACKEND=wayland`. [Using GTK with Wayland](https://docs.gtk.org/gtk4/wayland.html): on UNIX Wayland is default; `WAYLAND_DISPLAY` / `XDG_RUNTIME_DIR` locate the compositor (niri, mutter, weston, …). Backend choice is orthogonal to iGPU vs dGPU.

### Mesa (driver, not GTK)

[Mesa env vars](https://docs.mesa3d.org/envvars.html):

- `LIBGL_ALWAYS_SOFTWARE=true` — always software GL. Forbidden.
- `DRI_PRIME` — “the default GPU is the one used by Wayland/Xorg or the one connected to a display.” Syntax `N`, `pci-…`, `vendor_id:device_id`. Vulkan: trailing `!` exposes **only** that device.
- `MESA_VK_DEVICE_SELECT` — `list` or `vid:did`; optional `!` / `MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1` to hide other devices.
- `DRI_PRIME_DEBUG` / `MESA_VK_DEVICE_SELECT_DEBUG` — print selection.

**iGPU-only box:** leave these unset. The compositor’s GPU is the iGPU.

**Hybrid laptop (out of Kakuriyo’s required bar, but documented):** to *prefer* iGPU you typically **avoid** `DRI_PRIME=1` (that selects the *non-default* GPU, often the dGPU). Forcing iGPU on hybrid is `MESA_VK_DEVICE_SELECT=<iGPU vid:did>` / PCI form of `DRI_PRIME`, not a GTK API.

---

## NixOS packaging implications

This repo’s `shell.nix` already pulls `pkgs.gtk4` + `pkg-config` (Zig/Native era). A `gtk4-rs` binary needs the same **plus** a Rust toolchain; **Mesa / Vulkan ICDs stay the user’s NixOS graphics stack**, not vendored in the crate.

Implications:

- `nix-shell` / flake `buildInputs`: `gtk4`, `pkg-config`, and whatever gtk-rs sys crates need (`glib`, `cairo`, `pango`, `gdk-pixbuf`, `graphene`). Vulkan/GL come from `mesa` on the host; do not wrap `LIBGL_ALWAYS_SOFTWARE`.
- Store-wrapped binaries must see the same GL/Vulkan as other GTK apps (`LD_LIBRARY_PATH` / Nix wrapProgram patterns). Missing ICD → Vulkan renderer fails to realize → GSK falls through toward Cairo.
- CI without a GPU: GTK’s own suite uses headless compositors (`mutter --headless`, Weston headless) with `GTK_A11Y=none` and `GDK_BACKEND=wayland`. That environment may **not** have a real iGPU; a first-paint or “not Cairo” gate on GitHub-hosted runners can lie. Prefer the gate on a NixOS workstation with iGPU; CI can still compile and run unit tests.

No first-party GTK “NixOS iGPU” document exists. The constraint is ordinary Linux: GTK + Mesa + Wayland compositor.

---

## First-paint budget (800 ms locked window)

GSK GPU path creates a GL or Vulkan context on first realize. That is extra work vs Cairo, but Cairo is out of product scope.

GTK does **not** document a millisecond budget. Related clocks:

- [`GdkFrameClock`](https://docs.gtk.org/gdk4/class.FrameClock.html) — `update` → `layout` → `paint` → `after-paint`.
- `gdk_frame_clock_get_frame_time()` is animation time, not “window appeared.”
- Presentation time lives on `GdkFrameTimings` (`gdk_frame_timings_get_presentation_time`); it may be incomplete until the compositor reports.

Shader cache (`MESA_SHADER_CACHE_DIR` / XDG cache) can make **second** launch faster; the 800 ms bar is **cold** first paint of the **locked** UI, Argon2id excluded. Cold GL/Vulkan init is the risk, not Argon2.

Do not set `GSK_RENDERER=cairo` to “win” the budget.

---

## Spec text for the rewrite handoff

- Renderer: GSK GL or Vulkan as chosen by GTK for the Wayland surface. **Cairo = fail.**
- Device: display GPU; on iGPU-only NixOS that is the iGPU. No app-level CUDA. No `DRI_PRIME` in default launch.
- `GSK_RENDERER` unset in `run.sh` / packaged wrapper.
- Gate (separate ticket): after first mapped frame, `gtk_native_get_renderer` is not Cairo; optional local timer process-start → first `GdkFrameClock::after-paint`.

---

## Sources (primary)

1. GTK running / `GSK_RENDERER` — https://docs.gtk.org/gtk4/running.html  
2. `gsk_renderer_new_for_surface` (GSK_RENDERER then default then Cairo) — https://docs.gtk.org/gsk4/ctor.Renderer.new_for_surface.html  
3. GSK Renderer — https://docs.gtk.org/gsk4/class.Renderer.html  
4. GL renderer — https://docs.gtk.org/gsk4/class.GLRenderer.html  
5. Vulkan renderer (fail if no Vulkan) — https://docs.gtk.org/gsk4/class.VulkanRenderer.html  
6. Ngl deprecated 4.18 — https://docs.gtk.org/gsk4/ctor.NglRenderer.new.html  
7. Cairo renderer (software) — https://docs.gtk.org/gsk4/class.CairoRenderer.html  
8. `gtk_native_get_renderer` — https://docs.gtk.org/gtk4/method.Native.get_renderer.html  
9. Wayland backend — https://docs.gtk.org/gtk4/wayland.html  
10. Frame clock — https://docs.gtk.org/gdk4/class.FrameClock.html  
11. Mesa `DRI_PRIME`, `LIBGL_ALWAYS_SOFTWARE`, `MESA_VK_DEVICE_SELECT` — https://docs.mesa3d.org/envvars.html  
12. This repo `shell.nix` — `pkgs.gtk4`, `pkg-config` (GTK4 already in the NixOS dev shell)
