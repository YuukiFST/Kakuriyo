# Entry flexible fields

Type: grilling
Status: resolved
Blocked by:

## Question

What fields does an **Entry** have in v1? Title, optional URL, body/secret text, phone, tags-inside-entry, created/updated — which are required vs optional? Confirm “one flexible type” still holds when nesting URLs with free text (passwords, phones, notes) in the same Entry.

## Answer

**One flexible Entry type** (no link/note/password product split).

| Field | v1 rule |
| --- | --- |
| **Title** | Required; reject blank/whitespace |
| **URL** | Optional; at most one; soft validation; Preview only when present |
| **Body** | Optional plain-text multiline; phones/secrets/extra links live here — no dedicated Phone field |
| **Tags** | None on Entry (Collections organize) |
| **created / updated** | Stored; shown read-only in detail chrome; not user-editable |

Title-only Entries allowed (empty URL + Body). Glossary updated: `Title`, `Body`, sharpened `Entry` in `Kakuriyo/CONTEXT.md`.
