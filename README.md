# Kakuriyo

Local encrypted personal vault for **Entries** in nested **Collections**.
Linux/NixOS desktop, offline-first, no telemetry. No Vim Motion.

Vault envelope is Zig (Argon2id + XChaCha20-Poly1305). Session UI is Zig
`AppController` + `app_view.zig`. `src/core.ts` holds number slots only.

## Run

```sh
./run.sh    # or: npm start
```

Enters `nix-shell` when needed, builds Debug, opens the GTK window.
Needs `DISPLAY` / `WAYLAND_DISPLAY` and `native` on PATH.

## Flows

1. **Master** — first launch: password + confirm (min 8). Later: unlock with master only.
2. **Folders + links** — left: Collections. Center: Entries in the selected folder. Right: title/URL/notes + Preview.
3. **Paste** — dump many `http(s)://` URLs. Optional **Save as folder** names the Collection (`XYZ`). Empty name: selected folder, or **Inbox** at root. The batch stays together (no host split).
4. **Preview** — cache from the Vault on select (no network). **Refresh** fetches with an 800ms budget; images over 128 KiB are dropped.
5. **Lock** — saves dirty entry if needed, drops the DEK.

Screencast black-out on **niri**: see [docs/niri-screencast.md](docs/niri-screencast.md).

## Gates

```sh
npm install
npm install --prefix vendor/native-sdk/packages/core
nix-shell --run "npm run gate"
```

See [GATES.md](GATES.md).

## Editor / build notes

`package.json` and `tsconfig.json` are the editor TypeScript surface.
`src/app.native` is a placeholder; paint lives in `src/app_runner/app_view.zig`.

## Requirements

Node.js 22.15+ (on the 23 line: 23.5+) on PATH. Zig comes from `nix-shell`.
