# Kakuriyo

Local encrypted personal vault: **Links** (bulk URL ingest + cached preview)
and **Senhas** (second gate + secrets). Desktop-only, offline-first, no telemetry.

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
2. **Links** — paste `http(s)://` URLs, **Ingerir**. Collections group by host (`www.` stripped). Select an entry: preview title/description/thumbnail come from vault cache (no network). **Refresh** fetches with an 800ms budget; images over 128 KiB are dropped.
3. **Senhas** — first visit: create a gate password (uppercase + lowercase + digit + special). Later visits in the same master session stay unlocked if you already opened Senhas; **Lock** (or process exit) clears the Senhas session. Secrets: label, username, password, notes. Secret values are not required to match the gate policy.
4. **Lock** — saves dirty entry if needed, drops the DEK, drops Senhas gate unlock.

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
