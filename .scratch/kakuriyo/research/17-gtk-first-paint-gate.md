# Research: Gate locked first paint under 800 ms

**Ticket:** [How to gate GTK4 locked first paint under 800 ms?](https://github.com/YuukiFST/Kakuriyo/issues/48)  
**Question:** How can a gate **fail** if locked-window first paint exceeds **800 ms** (process start → first presented locked UI; Argon2id excluded)?  
**Sources:** GDK FrameClock / FrameTimings, GTK running/a11y, GTK headless Wayland tests, Kakuriyo `GATES.md` shape.

---

## Verdict

**Clock:** `std::time::Instant` at the first line of `main` (before `gtk::init`).  
**Event:** first `GdkFrameClock::after-paint` on the locked window’s surface clock.  
**Fail:** elapsed **> 800 ms**, or GSK renderer is **Cairo** (see [14-gtk4-gsk-igpu-nixos.md](https://github.com/YuukiFST/Kakuriyo/blob/research/gtk4-gsk-igpu-nixos/.scratch/kakuriyo/research/14-gtk4-gsk-igpu-nixos.md)).

Do **not** wait on `gdk_frame_timings_get_presentation_time` as the sole signal: docs say it is **0** until timings are complete, and completeness can lag or never fill on some backends.

Do **not** run this gate on GitHub `ubuntu-latest` without a Wayland compositor + GPU and call it the product number. Shape: **local / NixOS workstation gate** (like today’s `npm run gate` on a real display). CI compiles `cargo test` and skips first-paint unless `WAYLAND_DISPLAY` + a real (or mutter-headless) session exists.

Unlock / Argon2id must not run before that first paint. Locked UI is password field + chrome only.

---

## GDK facts

[`GdkFrameClock`](https://docs.gtk.org/gdk4/class.FrameClock.html): phases `update` → `layout` → `paint` → [`after-paint`](https://docs.gtk.org/gdk4/signal.FrameClock.after-paint.html) (“ends processing of the frame”). GTK says apps generally should not handle `after-paint`; a **one-shot test harness** may.

[`gdk_frame_timings_get_presentation_time`](https://docs.gtk.org/gdk4/method.FrameTimings.get_presentation_time.html): time the frame became visible, `g_get_monotonic_time()` timescale, or **0** if unavailable. Pair with [`gdk_frame_timings_get_complete`](https://docs.gtk.org/gdk4/method.FrameTimings.get_complete.html) — incomplete timings mean “not yet / never”.

Gate definition for Kakuriyo: **toolkit finished the first locked paint**. Compositor-to-photons may be later; 800 ms is still this metric (matches “first mapped/presented frame” as far as GTK can honestly see).

Optional extra: if `get_complete()` and `presentation_time != 0`, also assert `presentation_time - process_start ≤ 800 ms` in microseconds via `g_get_monotonic_time()` captured at start — **only when complete**. Primary fail is still `Instant` + `after-paint`.

Renderer check: `gtk_native_get_renderer` not `GskCairoRenderer`.

---

## Harness shape

Binary or `#[ignore]` test `first_paint_locked`, invoked by `tools/gates/gate-first-paint.sh`:

1. `GTK_A11Y=none` — GTK running docs: test backend recommended for CI; `none` disables a11y cost.  
2. `GDK_BACKEND=wayland` when on Wayland.  
3. Do **not** set `GSK_RENDERER=cairo`.  
4. Show only the locked window (`present`).  
5. Connect `after-paint` once; quit the main loop; print `FIRST_PAINT_MS=` and exit 1 if `> 800`.

Headless (GTK’s own suite): `GTK_A11Y=none`, mutter `--headless --virtual-monitor … --wayland-display …`, `GDK_BACKEND=wayland` ([gtk `run-headless-wayland-tests.sh`](https://github.com/GNOME/gtk/blob/8873db5d/testsuite/headless/run-headless-wayland-tests.sh)). Weston 14.0.1 notes gtk4 crashes on an older headless bug — prefer **mutter** as GTK does.

NixOS CI VM without GPU: this number is not the iGPU budget. Skip with `exit 0` + banner if no `WAYLAND_DISPLAY`, or run mutter-headless as **smoke** (not the 800 ms SLA). Document: SLA gate is `nix-shell --run tools/gates/gate-first-paint.sh` on the developer machine.

Match existing gate **shape**: one script, non-zero on fail, listed in `GATES.md` / `gates.sh` replacement (`cargo test` + this script).

---

## What not to use

- Time-to-`Application::activate` only — no paint yet.  
- `g_timeout_add(800)` as a pass — that cannot fail late paint.  
- Measuring Unlock.  
- Xvfb + Cairo as a “fast” cheat.

---

## Sources (primary)

1. FrameClock — https://docs.gtk.org/gdk4/class.FrameClock.html  
2. `after-paint` — https://docs.gtk.org/gdk4/signal.FrameClock.after-paint.html  
3. Presentation time — https://docs.gtk.org/gdk4/method.FrameTimings.get_presentation_time.html  
4. Timings complete — https://docs.gtk.org/gdk4/method.FrameTimings.get_complete.html  
5. `GTK_A11Y`, `GDK_BACKEND` — https://docs.gtk.org/gtk4/running.html  
6. Wayland — https://docs.gtk.org/gtk4/wayland.html  
7. GTK headless Wayland driver — https://github.com/GNOME/gtk/blob/8873db5d/testsuite/headless/run-headless-wayland-tests.sh  
8. Kakuriyo gate shape — `GATES.md`, `tools/gates/gates.sh`
