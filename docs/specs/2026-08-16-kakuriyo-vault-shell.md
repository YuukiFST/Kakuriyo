# Kakuriyo vault shell redesign

Date: 2026-08-16

## Destination

A usable Linux/NixOS Kakuriyo: encrypted local Vault, nested Collections, bulk URL paste, Collection tree + Entry list + Preview, classic keyboard, niri screencast block-out. Spec plus this implementation.

## Decisions (locked)

- **Surface:** Native process (Zig + Native SDK / GTK). No Electron, no hosted web, no sudo.
- **OS:** Linux only for this effort (NixOS first). Windows out of scope.
- **Crypto:** User process. Vault encrypted at rest (existing Argon2id + XChaCha20-Poly1305). Unlock with Master Password. Auto-lock. Not sudo.
- **Screen Block-out:** Requires **niri**. Document `window-rule` matching `dev.yuukifst.kakuriyo` with `block-out-from "screencast"`. i3+X11 cannot paint black-in-stream while showing the window.
- **Organization:** Collections (folders), not tags. Nesting is `Movies` → `QBitTorrent`. No status field on Entry.
- **Paste:** Many `http(s)` URLs at once. Optional folder name creates/reuses that Collection under the selected parent. Empty name: selected Collection, or Inbox at root. All URLs in one batch stay together (no host-split in the UI path).
- **Chrome:** Folders left, links of the selected folder center, title/URL/notes + Preview right. No Vim Motion. No Links/Passwords activity bar.
- **Keyboard:** Arrows, Tab/focus, Enter, Delete confirm, Ctrl+F filter, Ctrl+Shift+L lock, Ctrl+Enter open URL. Letter keys never move the tree.
- **Cost 0:** No paid SaaS, no Discord bot/API, no cloud.

## Out of scope

- Windows ExcludeFromCapture
- Vim Motion
- Discord bot migrate
- Classifier that guesses author vs work
- Hosted PWA
- Password-manager product tab as primary chrome
