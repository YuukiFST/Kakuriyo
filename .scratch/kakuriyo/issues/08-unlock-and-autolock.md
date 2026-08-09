# Unlock and Auto-lock policy

Type: grilling
Status: resolved
Blocked by:

## Question

First-run Vault creation, Unlock screen, Auto-lock triggers (idle duration, minimize, exit), failed Master Password attempts, and change-password flow — what is in v1 vs later?

## Answer

**v1 Unlock / Auto-lock policy**

### First-run
- Create Master Password: password + confirm; **hard min length 8**.
- Vault file lands in **default OS app-data path**; no folder picker in v1.

### Unlock screen
- Master Password field + Unlock only (no biometrics, no hint, no wipe/reset control).
- Show/hide password toggle on Unlock, create, and change-password.

### Failed attempts
- After **5** wrong Unlock attempts → **5 min** lockout on Unlock screen only.
- No automatic Vault wipe.
- Change-password “current password” failures: immediate error only (no lockout).

### Auto-lock triggers
- **Idle**: no keyboard/mouse input **in the app**. Default **5 min**. Settings presets: **1 / 5 / 15 / 30 min + Never**.
- **Quit**: closing the window **quits** the app and locks (no tray yet; tray stays fog).
- **Minimize**: optional; **OFF** by default (Settings toggle).
- Before Auto-lock: **auto-save** any dirty Entry, then lock.

### Change Master Password (v1)
- Settings: **current + new + confirm**; rewrap DEK with new Argon2id KEK (per crypto ticket).

### Post-Unlock
- Restore last Collection/Entry focus.
