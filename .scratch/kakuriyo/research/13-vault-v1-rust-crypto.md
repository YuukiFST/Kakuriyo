# Research: Rust crates that reproduce vault v1 bytes

**Ticket:** [Which Rust crates reproduce vault v1 bytes with Zig files?](https://github.com/YuukiFST/Kakuriyo/issues/44)  
**Question:** Which Rust crates and APIs round-trip Kakuriyo **vault v1** with current Zig `src/vault/vault.zig` (Unlock/save both ways)?  
**Sources:** this repo’s vault module, Zig `std.crypto` Argon2, RustCrypto crate docs.

---

## Verdict

Use **RustCrypto**, not orion/libsodium, for the envelope:

| Role | Crate | API |
| --- | --- | --- |
| KDF | [`argon2`](https://docs.rs/argon2/latest/argon2/) | `Argon2::new(Algorithm::Argon2id, Version::V0x13, params).hash_password_into(password, salt, &mut kek)` — **not** the PHC `hash_password` string API |
| AEAD | [`chacha20poly1305`](https://docs.rs/chacha20poly1305/latest/chacha20poly1305/) | `XChaCha20Poly1305` + 24-byte `XNonce`; `Payload { msg, aad: b"kakuriyo/vault-v1" }` |
| Wipe | [`zeroize`](https://docs.rs/zeroize/latest/zeroize/) | `Zeroizing<[u8; 32]>` / `ZeroizeOnDrop` for KEK, DEK, password buffers (Zig `secureZero`) |
| RNG | `getrandom` / `rand::rngs::OsRng` | salt, DEK, nonces — same role as Zig `io.random` |

Do **not** use `crypto_secretbox` (XSalsa20, NaCl). Do **not** use age/scrypt. Orion is a second independent implementation; extra mismatch risk for zero gain.

Interop is **the same algorithms + the same byte layout**. RustCrypto is RFC/draft-compatible with Zig `std.crypto`; the rewrite still needs a **cargo oracle** that decrypts a Zig-written fixture (and vice versa). That test is an implementation gate, not a crate change.

---

## What Zig actually does

From `src/vault/vault.zig`:

- Magic `KAKU`, version `1`, AAD `kakuriyo/vault-v1` (17 bytes).
- Header 132 bytes; payload region is `ciphertext \|\| 16-byte tag` (`min_file_len` 148).
- Argon2id via `std.crypto.pwhash.argon2.kdf` with `Params{ .t, .m, .p }` from the file (`m` = KiB). Default `{ m=19*1024, t=2, p=1 }`.
- Zig std Argon2 pins **version `0x13`** (`lib/std/crypto/argon2.zig`).
- `XChaCha20Poly1305.encrypt(ct, &tag, plaintext, aad, nonce, key)` then tag **appended** after ciphertext (DEK wrap: 32 ct + 16 tag = 48).
- Lock: `std.crypto.secureZero` on DEK and payload.

On-disk field order (big-endian ints) is locked in `docs/superpowers/plans/2026-08-09-vault-v1-envelope.md`. Rust must parse that header; crates do not invent a second format.

---

## Rust mapping (must-match)

### Argon2id KEK

Zig `kdf(..., .argon2id)` ≡ RFC 9106 Argon2id v1.3.

RustCrypto:

```rust
use argon2::{Algorithm, Argon2, Params, Version};

let params = Params::new(m_cost, t_cost, p_cost, Some(32))?;
let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
argon2.hash_password_into(password, &salt, &mut kek)?;
```

- `m_cost` is **KiB**, same as Zig `.m` and the u32be at header offset 8.
- Output length **32** (KEK).
- Salt is raw 16 bytes, not a PHC salt string.
- `Argon2::default()` is OWASP-shaped (`t=2`, `m=19*1024`, `p=1`) but Unlock **must** use params **from the file**, not defaults.

### XChaCha20-Poly1305

Zig and RustCrypto both use the XChaCha construction (24-byte nonce, 16-byte Poly1305 tag).

```rust
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};

let cipher = XChaCha20Poly1305::new((&dek).into());
let nonce = XNonce::from_slice(&nonce24);
let ct = cipher.encrypt(
    nonce,
    Payload { msg: plaintext, aad: b"kakuriyo/vault-v1" },
)?;
// `ct` is ciphertext || tag — same as Zig’s concat
```

Passing only `&[u8]` (no `Payload`) authenticates **empty** AAD and **will not** open Zig files.

Tag-split: Zig decrypt takes `ct` and `tag` separately; Rust `decrypt` wants `ciphertext||tag`. Concatenate on the Rust side.

### Password change

Rewrap DEK only: new salt (and same stored m/t/p unless rotating), new KEK, new `dek_nonce` + `wrapped_dek`. Payload nonce + payload ct **byte-identical**. No extra crate.

---

## Rejected alternatives

| Stack | Why not |
| --- | --- |
| `orion` | Another Argon2/XChaCha impl; no Zig interop evidence in-tree; two libraries to audit |
| `libsodium` / `sodiumoxide` | Native dep; secretbox is XSalsa by default |
| `crypto_secretbox` | Explicitly NaCl XSalsa, not XChaCha |
| `age` | scrypt passphrase path; full-file rewrite on password change |
| PHC `argon2::hash_password` | Encodes a password-hash string, not a 32-byte KEK |

---

## Implementation checklist (for the rewrite, not this ticket)

1. Fixture: Zig `create` + `save` known payload in tests; Rust Unlock must match bytes.
2. Reverse fixture: Rust write, Zig `unlock` in `zig build test-vault` (keep Zig tests until cutover).
3. Mutants that already exist for AAD/nonce/rewrap stay valid as cargo tests.

---

## Sources (primary)

1. `src/vault/vault.zig` — envelope, AAD, wrap/unwrap, tag placement  
2. Vault v1 plan — `docs/superpowers/plans/2026-08-09-vault-v1-envelope.md`  
3. Zig Argon2 `version = 0x13`, `pub fn kdf` — https://raw.githubusercontent.com/ziglang/zig/master/lib/std/crypto/argon2.zig  
4. RustCrypto argon2 KDF example — https://docs.rs/argon2/latest/argon2/  
5. `Params::new(m_cost, t_cost, p_cost, output_len)` — https://docs.rs/argon2/latest/argon2/struct.Params.html  
6. `Algorithm::Argon2id`, `Version::V0x13` — https://docs.rs/argon2/latest/argon2/enum.Algorithm.html · https://docs.rs/argon2/latest/argon2/enum.Version.html  
7. `XChaCha20Poly1305` — https://docs.rs/chacha20poly1305/latest/chacha20poly1305/  
8. `aead::Payload` `{ msg, aad }` — https://docs.rs/aead/latest/aead/struct.Payload.html  
9. `zeroize` — https://docs.rs/zeroize/latest/zeroize/  
10. Prior algorithm research — `.scratch/kakuriyo/research/03-encrypted-vault-at-rest.md`
