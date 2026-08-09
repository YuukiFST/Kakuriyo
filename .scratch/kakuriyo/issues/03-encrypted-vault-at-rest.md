# Encrypted Vault at rest

Type: research
Status: resolved
Blocked by:

## Question

For a **$0**, offline, single-device Vault unlocked by **Master Password**: what established Rust patterns / libraries give encryption at rest (KDF + authenticated encryption), safe Unlock / Auto-lock memory handling, and an exportable encrypted backup file — without a cloud KMS? Recommend a concrete approach and what not to invent.

## Answer

**Envelope encryption:** random DEK wrapped by Argon2id-derived KEK; vault payload with XChaCha20-Poly1305 (`argon2` + `chacha20poly1305` + `secrecy`/`zeroize`). Backup = copy of ciphertext (optional `age` passphrase export). Don’t invent ciphers/KDFs; no KMS needed.

Detail: [research/03-encrypted-vault-at-rest.md](../research/03-encrypted-vault-at-rest.md)
