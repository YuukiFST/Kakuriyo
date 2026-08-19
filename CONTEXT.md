# Kakuriyo

Local encrypted personal vault for private Entries (links and other text), organized in nested Collections. Linux/NixOS desktop, offline-first, no telemetry.

## Language

**Kakuriyo**:
The product — a standalone Linux/NixOS desktop vault (NixOS first). Not a Discord server, not a password-manager suite, not a hosted site.
_Avoid_: Links Manager, bookmark manager, Discord self-chat, Windows-first app

**Vault**:
The user's encrypted store on one machine; unlocked with a Master Password.
_Avoid_: database, account, library

**Master Password**:
The secret that unlocks the Vault and decrypts it at rest. Process runs as the user, never root/sudo.
_Avoid_: PIN-only, login, account password, sudo password

**Unlock**:
The act of accepting the Master Password and opening the Vault for use.
_Avoid_: login, sign-in, authenticate (no remote auth)

**Auto-lock**:
Returning the Vault to a locked state after idle or when the app closes, requiring Unlock again.
_Avoid_: logout, session timeout (as remote-session metaphor)

**Collection**:
A named folder that groups Entries; Collections may nest inside Collections. An Entry lives in exactly one Collection. Optional name on a paste batch creates or reuses that Collection. Unnamed paste into Vault root lands in Inbox.
_Avoid_: tab, tag, board, playlist, channel

**Inbox**:
The default Collection created when a batch of URLs is saved with no folder name while nothing else is selected.
_Avoid_: unsorted dump, root entries (as the default paste target)

**Entry**:
One vault item of a single flexible type: required Title, optional URL, optional Body, plus created/updated timestamps. Not split into link/note/password product types.
_Avoid_: bookmark, link (as the only type), password, note (as separate product types), typed item

**Title**:
The required display name of an Entry; cannot be blank or whitespace-only.
_Avoid_: name, label, subject

**Body**:
The optional plain-text field on an Entry for freeform content.
_Avoid_: Notes (as the field name in domain), markdown document; Password field (as a product type)

**Preview**:
The visual card (title/image/metadata) shown for an Entry that has a URL.
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
