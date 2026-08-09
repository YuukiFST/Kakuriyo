# Main layout prototype

Type: prototype
Status: resolved
Assigned to: pi session
Blocked by: 05

## Question

What does the main Kakuriyo chrome feel like with nested Collections, Entry list, and Preview/detail pane (dark UI, keyboard-first)? Produce a cheap prototype (outline or gpui/stub UI) to react to — layout density, focus rings, and how nesting appears — not production polish.

## Answer

**v1 chrome = Variant B — IDE editor + Preview**, TRUE BLACK palette (`#000` / gray chrome; not soft dark-gray themes from r1).

| Piece | Decision |
| --- | --- |
| **Shell** | Activity bar (EX / SR / LK) + Explorer tree (Collections + Entries as leaves) + main split: Entry editor \| Preview |
| **Nesting** | Classic tree indent + twisty ▸▾; Entries appear **in the tree** under their Collection (B), not a middle list pane |
| **Preview weight** | Dominant right half of the main split (~50%); OG when URL present; idle when no URL |
| **Palette** | TRUE BLACK — rejected earlier non-black dark palettes |
| **Focus / density** | Deferred to [Keyboard-first navigation](07-keyboard-navigation.md) |
| **Secrets in editor** | Still **one Entry type**. Soft structured rows (User + Password Show/Hide + Copy) over Body; not a Password product type. Toggle to plain Body remains available in prototype; **structured is the preferred v1 presentation** for secret-heavy Entries |
| **Tree badge** | Secret-ish Entries show `•••` in the Explorer meta column (visual hint only) |

Prototype asset: [prototypes/06-main-layout.html](../prototypes/06-main-layout.html) (`?variant=B`, sample Logins → Work → GitHub).
