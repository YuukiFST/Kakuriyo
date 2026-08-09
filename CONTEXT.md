# Kakuriyo

Local encrypted personal vault for private Entries (links and other text), organized in nested Collections. Desktop-only, offline-first, no telemetry.

## Language

**Kakuriyo**:
The product — a standalone desktop vault app (Windows 11 and Linux/NixOS).
_Avoid_: Links Manager, bookmark manager, Discord self-chat

**Vault**:
The user's encrypted store on one machine; unlocked with a Master Password.
_Avoid_: database, account, library

**Master Password**:
The secret that unlocks the Vault and decrypts it at rest.
_Avoid_: PIN-only (unless later chosen), login, account password

**Unlock**:
The act of accepting the Master Password and opening the Vault for use.
_Avoid_: login, sign-in, authenticate (no remote auth)

**Auto-lock**:
Returning the Vault to a locked state after idle or when the app closes, requiring Unlock again.
_Avoid_: logout, session timeout (as remote-session metaphor)

**Collection**:
A named folder that groups Entries; Collections may nest inside Collections. An Entry lives in exactly one Collection or directly in the Vault root (Collections are folders, not tags).
_Avoid_: tab, tag, board, playlist

**Entry**:
One vault item of a single flexible type: required Title, optional URL, optional Body, plus created/updated timestamps. Not split into link/note/password product types.
_Avoid_: bookmark, link (as the only type), password, note (as separate product types), typed item

**Title**:
The required display name of an Entry; cannot be blank or whitespace-only.
_Avoid_: name, label, subject

**Body**:
The optional plain-text field on an Entry for freeform content (notes, secrets, phone numbers, extra links as text). Structured User/Password rows in the editor are a presentation over Body, not separate stored fields or a second Entry type.
_Avoid_: Notes, Content, description, Secret (as the field name); markdown document; Password field (as a product type)

**Preview**:
The visual card (title/image/metadata) shown for an Entry that has a URL, typically in the right-hand panel of the IDE-style split.
_Avoid_: thumbnail-only, embed, iframe

**Export**:
Writing a portable encrypted copy of the Vault file (`.kakuriyo`) for manual transfer between machines; not sync.
_Avoid_: sync, cloud backup, age export (v1)

**Import**:
Loading a `.kakuriyo` Vault file into Kakuriyo while unlocked, after prompting for that file's Master Password.
_Avoid_: restore (ambiguous), open (as generic file open), sync pull

**Replace**:
Import mode that swaps the current Vault for the imported file after an automatic local `.bak` of the previous Vault.
_Avoid_: overwrite without backup, merge

**Merge**:
Import mode that combines Entries and Collections from a backup into the current Vault by stable UUID, asking the user on each conflict.
_Avoid_: sync, automatic last-write-wins without prompt
