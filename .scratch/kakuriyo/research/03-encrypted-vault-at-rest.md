# Research: Encrypted Vault at rest (offline, Master Password, $0)

**Ticket:** [issues/03-encrypted-vault-at-rest.md](../issues/03-encrypted-vault-at-rest.md)  
**Scope:** Single-device desktop vault; no cloud KMS; Unlock / Auto-lock; exportable encrypted backup.  
**Sources:** primary docs only (OWASP, age/C2SP, libsodium, RustCrypto / crates.io docs).

---

## Verdict

Use **envelope encryption**: random **DEK** + **Argon2id**-derived **KEK** + **XChaCha20-Poly1305** AEAD via RustCrypto crates (`argon2`, `chacha20poly1305`, `rand`/`getrandom`, `zeroize`, `secrecy`). Store one versioned binary vault file on disk. Treat **export backup** as a copy of that ciphertext (or an `age` passphrase-wrapped export for interoperability). Do **not** invent algorithms, modes, or KDFs; do not require a KMS.

---

## Threat model (fits Kakuriyo)

| Threat | Covered by |
| --- | --- |
| Disk theft / casual file copy while locked | Authenticated encryption at rest; secrets not in plaintext on disk |
| Tampering with vault file | AEAD tag failure on decrypt |
| Offline password guessing | Memory-hard Argon2id with stored salt + params |
| Secrets left in RAM after lock | `secrecy` + `zeroize` / drop unlocked state |

Not covered (and not claimed): cold-boot / DMA / malware with full process memory while unlocked; OS swap scraping beyond best-effort zeroize. OWASP: application-level encryption is appropriate when threat is storage compromise, not a fully compromised live process ([Cryptographic Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html)).

---

## Established pattern: KEK / DEK envelope

OWASP explicitly recommends deriving a **KEK from a passphrase** and wrapping a randomly generated **DEK**, so password change re-wraps the DEK without re-encrypting all data ([Cryptographic Storage — Encrypting Stored Keys](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#encrypting-stored-keys)):

1. Generate **DEK** = 32 bytes CSPRNG (never from the password alone).
2. Generate **salt** = CSPRNG (≥16 bytes; Argon2 recommended salt length in crate docs).
3. **KEK** = Argon2id(password, salt, params) → 32 bytes (`argon2::Argon2::hash_password_into` for key derivation, not the PHC-string auth API — [argon2 docs](https://docs.rs/argon2/latest/argon2/)).
4. Encrypt DEK under KEK with AEAD → `wrapped_dek`.
5. Encrypt vault plaintext under DEK with AEAD → `ciphertext`.
6. Persist: magic/version, KDF params, salt, nonces, `wrapped_dek`, `ciphertext` (and optional AAD fields bound into AEAD).

Unlock = recompute KEK → unwrap DEK → decrypt payload. Wrong password ⇒ AEAD failure (no separate “password hash” required for verification).

Auto-lock = drop unlocked session (plaintext model + DEK + any password buffers); rely on `ZeroizeOnDrop` / `SecretBox` so wipe is automatic.

---

## Concrete Rust stack (recommended)

| Role | Choice | Why / source |
| --- | --- | --- |
| KDF | **Argon2id** via [`argon2`](https://docs.rs/argon2/latest/argon2/) | OWASP first choice ([Password Storage](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)); RustCrypto; libsodium default PHF is Argon2id ([libsodium password hashing](https://doc.libsodium.org/password_hashing)) |
| KDF params (baseline) | `m_cost = 19456` (19 MiB), `t_cost = 2`, `p_cost = 1` | Matches OWASP Argon2id minimum and `argon2::Params::DEFAULT` (`DEFAULT_M_COST = 19 * 1024`, `DEFAULT_T_COST = 2`, `DEFAULT_P_COST = 1`) — [params.rs](https://raw.githubusercontent.com/RustCrypto/password-hashes/master/argon2/src/params.rs) |
| Desktop tuning | Raise toward libsodium `MODERATE` / `SENSITIVE` if UX allows | Interactive desktop: ~1–5 s OK ([libsodium guidelines](https://doc.libsodium.org/password_hashing/default_phf)); store params beside salt so upgrades are possible |
| AEAD | **XChaCha20-Poly1305** via [`chacha20poly1305`](https://docs.rs/chacha20poly1305/latest/chacha20poly1305/) | Authenticated encryption; 192-bit nonce → random nonces without counter bookkeeping; audited RustCrypto implementation notes NCC Group review on page |
| RNG | `OsRng` / `getrandom` for salts, DEK, nonces | OWASP: CSPRNG only ([Cryptographic Storage](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#secure-random-number-generation)) |
| Secret memory | [`secrecy`](https://docs.rs/secrecy/latest/secrecy/) (`SecretString`, `SecretBox`) + [`zeroize`](https://docs.rs/zeroize/latest/zeroize/) | Explicit expose + wipe on drop; zeroize warns about compiler elision and stack copies |
| Optional FFI | libsodium / `sodiumoxide` / `libsodium-sys` | Same primitives (Argon2id + secretbox); heavier native dep. Prefer pure RustCrypto unless you already need libsodium |

**AEAD algorithm note:** Prefer **XChaCha20-Poly1305** over IETF ChaCha20-Poly1305 for vault blobs (random 24-byte nonces). Prefer it over NaCl **XSalsa20-Poly1305** `crypto_secretbox` for new designs — `chacha20poly1305` docs point new work at XChaCha; `crypto_secretbox` is mainly for NaCl interop and carries a stronger “no audit” warning ([crypto_secretbox](https://docs.rs/crypto_secretbox/latest/crypto_secretbox/), [libsodium secretbox](https://doc.libsodium.org/secret-key_cryptography/secretbox)).

**OWASP cipher guidance:** Use authenticated modes (GCM/CCM called out as preferred block modes); do not invent custom algorithms ([Cryptographic Storage — Algorithms / Cipher Modes](https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html#algorithms)). ChaCha20-Poly1305 / XChaCha20-Poly1305 are established AEADs (RFC 8439; XChaCha draft + libsodium/WireGuard practice per crate docs).

---

## Suggested on-disk layout (application format — compose standards, don’t invent crypto)

Versioned header + ciphertext (illustrative; exact encoding is app protocol, not a new cipher):

```
magic | version | argon2_m | argon2_t | argon2_p | salt | dek_nonce | wrapped_dek | payload_nonce | ciphertext
```

- Bind `version` (and any AAD you care about) into AEAD associated data so header can’t be silently swapped.
- Atomic replace on save (write temp → fsync → rename) to avoid torn vaults.
- One file = whole vault at rest while locked.

Password change: new salt/params → new KEK → re-wrap same DEK; payload untouched.

---

## Unlock / Auto-lock memory handling

From primary crate + libsodium guidance:

1. Hold Master Password in `secrecy::SecretString`; never `Debug`/`Display` it ([secrecy](https://docs.rs/secrecy/latest/secrecy/)).
2. Derive KEK into a `Zeroizing<[u8; 32]>` / `SecretBox`; unwrap DEK the same way.
3. Keep unlocked plaintext in a session object that implements `ZeroizeOnDrop`; on Auto-lock / Lock, drop the session (and any UI string caches of secrets).
4. libsodium: plaintext passwords should not linger; `sodium_mlock` / `sodium_munlock` is the stronger OS-level option if you later add FFI ([default_phf notes](https://doc.libsodium.org/password_hashing/default_phf)). Pure-Rust path: `secrecy` + `zeroize` is the established crate pattern; do not expect register wipe or full anti-swap guarantees ([zeroize scope limits](https://docs.rs/zeroize/latest/zeroize/)).
5. Prefer heap-backed secret buffers sized up-front; avoid `Vec` growth that leaves old copies (zeroize docs).

---

## Exportable encrypted backup (no cloud)

Three established options; pick by product need:

| Approach | How | Pros | Cons |
| --- | --- | --- | --- |
| **A. Copy vault file** | Export = duplicate of on-disk ciphertext | Zero extra crypto; backup = vault | Tied to Kakuriyo format |
| **B. age passphrase file** | `age::Encryptor::with_user_passphrase` / `scrypt::Recipient` ([age Rust crate](https://docs.rs/age/latest/age/), [age-encryption.org](https://age-encryption.org/), [c2sp.org/age](https://c2sp.org/age)) | Interoperable with `age`/`rage` CLI; streaming; header MAC + ChaCha20-Poly1305 STREAM payload | Passphrase path uses **scrypt** (not Argon2id) per age v1 spec; re-encrypts whole payload as a new age file |
| **C. age to X25519 identity** | Encrypt backup to a user age public key | Strong key-based backup | Key management UX (store identity separately) |

**Recommendation for Kakuriyo:**  
- Day-to-day at-rest = **custom vault file (Argon2id + XChaCha20-Poly1305 envelope)** so Unlock stays Argon2id and password change is cheap.  
- Backup = **A** by default (file already encrypted); optionally **B** if you want a portable `.age` export users can open with stock `age`/`rage` tools.

Do **not** ship a second plaintext “backup JSON” and encrypt it with a homemade scheme.

---

## age as the *only* vault store?

Viable for a simple single-blob vault (`Encryptor::with_user_passphrase`), but weaker fit than envelope+Argon2id for this product:

- Passphrase recipient is **scrypt** (`N` as work-factor log, `r=8`, `p=1`) — [age v1 scrypt stanza](https://age-encryption.org/v1); OWASP prefers Argon2id when available.
- Entire file is one age ciphertext; password change implies full re-encrypt (age wraps a per-file key, but UX still rewrites the payload file).
- Still excellent for **export** and CLI interop ([rage](https://github.com/str4d/rage) / Go age).

---

## What not to invent

| Don’t | Do instead | Source |
| --- | --- | --- |
| Custom cipher / “XOR with hash of password” | Standard AEAD only | OWASP “Custom Algorithms: Don’t do this” |
| Unauthenticated CBC/CTR alone | AEAD (XChaCha20-Poly1305) | OWASP cipher modes |
| Fast hash (SHA-256) as password KDF | Argon2id | OWASP password storage |
| Derive DEK directly from password with no wrap | Random DEK + KEK wrap | OWASP envelope keys |
| Roll your own “encrypted zip” framing crypto | age format or thin versioned header around AEAD | age / C2SP |
| Homegrown memory wipe | `zeroize` / `secrecy` | crate docs |
| Cloud KMS / OS keychain as hard dependency | Optional later; password-derived KEK is enough for $0 offline | OWASP: KMS nice when available, not required for simple apps |
| Store Master Password encrypted “for convenience” | Never persist password; only salt+params+wrapped DEK | Password vs encryption distinction in OWASP |

---

## Minimal dependency set (Cargo)

```text
argon2
chacha20poly1305  # enable getrandom feature for nonce/key helpers
rand              # or getrandom via aead features
zeroize
secrecy
```

Optional: `age` (+ `armor` if ASCII export) for `.age` backups only.

---

## Implementation checklist (for build session)

1. Create vault: CSPRNG DEK + salt; Argon2id → KEK; wrap DEK; encrypt empty/serialized vault; atomic write.
2. Unlock: read header → Argon2id → unwrap DEK → decrypt → hold session in `Secret*` / zeroizing types.
3. Save: encrypt under existing DEK; same salt/params unless rotating KDF.
4. Change Master Password: new salt/params; re-wrap DEK only.
5. Lock / Auto-lock: drop session; clear UI secret fields.
6. Export: copy vault file and/or `age` passphrase-encrypt a snapshot.

---

## Sources (primary)

1. OWASP Cryptographic Storage Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html  
2. OWASP Password Storage Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html  
3. age format (C2SP / age-encryption.org/v1) — https://age-encryption.org/v1 · https://c2sp.org/age  
4. age project — https://age-encryption.org/  
5. Rust `age` crate — https://docs.rs/age/latest/age/  
6. RustCrypto `argon2` — https://docs.rs/argon2/latest/argon2/ · defaults in https://raw.githubusercontent.com/RustCrypto/password-hashes/master/argon2/src/params.rs  
7. RustCrypto `chacha20poly1305` / XChaCha20Poly1305 — https://docs.rs/chacha20poly1305/latest/chacha20poly1305/  
8. RustCrypto `zeroize` — https://docs.rs/zeroize/latest/zeroize/  
9. `secrecy` — https://docs.rs/secrecy/latest/secrecy/  
10. libsodium password hashing / Argon2id — https://doc.libsodium.org/password_hashing · https://doc.libsodium.org/password_hashing/default_phf  
11. libsodium secretbox — https://doc.libsodium.org/secret-key_cryptography/secretbox  
12. RustCrypto `crypto_secretbox` (legacy NaCl interop) — https://docs.rs/crypto_secretbox/latest/crypto_secretbox/  
