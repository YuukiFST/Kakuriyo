# Research: Relm4 + gtk-rs on nixpkgs

**Ticket:** [Which Relm4 and gtk-rs versions pin cleanly on nixpkgs?](https://github.com/YuukiFST/Kakuriyo/issues/46)  
**Question:** Which Relm4 + gtk-rs + GTK4 versions work together on NixOS first, and is Relm4 still right vs plain `gtk-rs`?  
**Sources:** crates.io / Relm4 changelog, gtk-rs docs, Relm4 `shell.nix`, this host’s `<nixpkgs>`.

---

## Verdict

**Use Relm4 0.11 + gtk4-rs 0.11.** Do **not** follow the Relm4 book’s stale `relm4 = "0.9.1"` snippet.

Measured on this machine’s `nixpkgs`:

| Piece | Version |
| --- | --- |
| `pkgs.gtk4` | **4.22.4** |
| `pkgs.rustc` | **1.95.0** |
| Host `rustc` (PATH) | 1.97.1 |

Relm4 **0.11.0** (2026-05-10): depends on `gtk4 ^0.11.2`, **MSRV 1.93**. nixpkgs 1.95 clears that. gtk4 crate **0.11.4**, MSRV 1.92.

Relm4 does **not** change GSK or first-paint physics; it is Elm-style widgets on the same GTK4. Keep Relm4. Skip **libadwaita** (TRUE BLACK IDE chrome, not Adwaita).

If a future nixpkgs `rustc` drops below 1.93, pin `fenix` / `rust-overlay` in the flake — do not downgrade Relm4 to 0.9 just to match an old book.

---

## Crate pins (Cargo.toml)

```toml
[dependencies]
relm4 = "0.11"
gtk = { package = "gtk4", version = "0.11" }
```

- `relm4` already depends on `gtk4 ^0.11.2`; an explicit `gtk4` pin avoids a second copy if app code uses gtk types directly.
- Default Relm4 features include macros. **Do not** enable `libadwaita` / `gnome_*` unless a later ticket needs Adwaita widgets.
- `relm4-components` optional; its `WebImage` pulls **reqwest** — Preview HTTP is a different crate (`ureq`). Do not take that component.

gtk-rs system library features (`v4_2` …) default to GTK 4.0 APIs. For 4.22 you *may* enable newer `v4_*` features; v1 Kakuriyo chrome (box, list, entry, password) does not require 4.22-only widgets. Prefer **default gtk4 features** until a widget needs a newer symbol.

---

## NixOS / nixpkgs

Rust crates come from **crates.io** (`Cargo.lock`). nixpkgs supplies **C libraries + rustc**, not Relm4.

Relm4’s own [`shell.nix`](https://github.com/Relm4/Relm4/blob/main/shell.nix) is the first-party Nix shape: `gtk4`, `pkg-config`, `wrapGAppsHook4`, `gdk-pixbuf`, `rustc`, `cargo`, `rustPlatform.bindgenHook`.

Kakuriyo `shell.nix` today is Zig+GTK4+Node. Rewrite shell (spec, not this ticket’s merge):

```nix
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    pkg-config
    rustc
    cargo
    wrapGAppsHook4
  ];
  buildInputs = with pkgs; [
    gtk4
    glib
    cairo
    pango
    gdk-pixbuf
    graphene
  ];
}
```

Packaging later: `rustPlatform.buildRustPackage` + `wrapGAppsHook4` (see nixpkgs `authenticator` for a GTK4+Rust wrap). Do **not** put gtk4 in `environment.systemPackages` and expect `pkg-config` to work — use the dev shell.

nixpkgs does not version-lock the `relm4` crate. Compatibility is: **C GTK4 ≥ 4.0** (4.22 is fine) + **rustc ≥ 1.93**.

---

## Relm4 vs plain gtk-rs

| | Relm4 0.11 | gtk-rs only |
| --- | --- | --- |
| Widgets / GSK | Same GTK4 | Same GTK4 |
| First paint | No extra WebView | Same |
| App structure | Components + `update` | Manual `connect_*` |
| Book | relm4.org (examples lag crates.io) | gtk-rs book |

Map preference was Relm4 if versions work. They do. Relm4 0.11 is the layer.

---

## Sources (primary)

1. crates.io `relm4` 0.11.0 — gtk4 `^0.11.2`, MSRV 1.93 — https://crates.io/crates/relm4  
2. Relm4 0.11.0 changelog — https://github.com/Relm4/Relm4/blob/main/CHANGES.md  
3. Relm4 book intro still shows `0.9.1` — **stale**; ignore for pin — https://relm4.org/book/stable/introduction.html  
4. Relm4 `shell.nix` — https://github.com/Relm4/Relm4/blob/main/shell.nix  
5. gtk4 crate 0.11.4 — https://crates.io/crates/gtk4  
6. gtk-rs install (Rust + GTK 4 library) — https://gtk-rs.org/gtk4-rs/git/book/installation.html  
7. This host: `nix-instantiate --eval -E '(import <nixpkgs> {}).rustc.version'` → `1.95.0`; gtk4 → `4.22.4`  
8. nixpkgs GTK4+Rust wrap example — https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/au/authenticator/package.nix
