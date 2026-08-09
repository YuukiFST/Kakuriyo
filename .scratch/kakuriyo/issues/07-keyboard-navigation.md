# Keyboard-first navigation

Type: grilling
Status: resolved
Assigned to: pi session
Blocked by: 06

## Question

Exact keyboard model: move Collection ↔ Entry ↔ Preview, open URL, create/edit/delete, search focus, lock Vault — which keys? Must match “pass link by link with Preview updating on the right” without requiring the mouse.

## Answer

**Model:** Vim Motion as optional navigation language (motions + focus-edits — not full Vim operators/Visual). **Default ON.** User can disable anytime. Match layout B (activity + tree-with-Entries + editor|Preview).

### Focus regions

| Region | Role |
| --- | --- |
| **Explorer tree** | Primary nav; Collections + Entries |
| **Editor** | Edit focused Entry fields |
| **Preview** | Follows tree selection immediately; not a 1st-level focus target |
| **Activity (EX / SR / LK)** | `1` = Explorer, `2` = Search view; Lock via `Ctrl-Shift-L` (LK mirrors) |

Preview updates on every Entry selection (j/k or arrows) — “pass link by link”.

### Vim Motion ON (default)

| Action | Keys |
| --- | --- |
| Move up/down | `j` / `k` (arrows alias) |
| Expand / collapse / parent | `l` expand; `h` collapse or parent if leaf (arrows ←→ alias) |
| Tree ↔ Editor | `Ctrl-w` `h`/`l` or `Ctrl-w` `w`; `Esc` → tree |
| Open URL (OS browser) | `gx` |
| New Entry | `a` — child of Collection context (if Entry focused → parent Collection) |
| New Collection | `A` — same context rule |
| Rename | `r` or `F2` (inline) |
| Delete | `Delete` only — modal confirm `y` / `Esc` (evacuate copy if Collection; see ticket 05) |
| Cut node (move) | `x` |
| Paste node | `p` — Collection focus → child; Entry focus → sibling. Cycle blocked (05) |
| Filter Explorer | `/` or `Ctrl-f` (v1 tree filter; full SR UX remains fog) |
| Lock Vault | `Ctrl-Shift-L` |
| Activity | `1` Explorer, `2` Search |

**Not in v1:** counts (`3j`), `gg`/`G`, Visual multi-select, `dd`/operators on text, Activity as focus pane.

### Editor isolation (anti-misfire)

With focus in Editor: letter keys type text. Tree motions (`hjkl`, `a`/`A`, `x`, `gx`, `r`) **dead**. Still live: `Esc` → tree, `Ctrl-w`*, Lock, search globals. **`Ctrl-C` / `Ctrl-X` / `Ctrl-V` always OS clipboard** — never tree move.

### Vim Motion OFF (Classic)

Toggle: **Settings → Keyboard** + command palette **“Toggle Vim Motion”**. **No mid-type hotkey** (avoids stealing keystrokes).

| Action | Keys |
| --- | --- |
| Move / nest | `↑↓←→` |
| Tree → Editor | `Enter` |
| Editor → Tree | `Esc` |
| Open URL | `Ctrl-Enter` |
| Rename / Delete | `F2` / `Delete` (same modal) |
| Move node | command/menu **Cut node** / **Paste node** — **not** `Ctrl-X`/`Ctrl-V` |
| Filter / Lock / Activity | same as ON (`/` or `Ctrl-f`, `Ctrl-Shift-L`, `1`/`2`) |

### Density + focus ring (from layout B deferral)

- Tree row height ~22–24px (compact IDE)
- Focus: inset 1px ring `#ffffff`
- Selection fill `#1c1c1c`

### Clipboard vs tree move (invariant both profiles)

OS clipboard (`Ctrl-C`/`X`/`V`) and tree relocate are **separate**. Move never rebinds clipboard shortcuts.
