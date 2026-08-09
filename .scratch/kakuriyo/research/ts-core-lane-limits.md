# The compiled-TS lane limits of @native-sdk/cli 0.8.3

Status: verified empirically (Task 1 of the vault-v1 plan); blocks any
command-issuing or routed-dispatch TS core until the SDK fixes the
scriptc compiled lane.

## Summary

On @native-sdk/cli 0.8.3 (scriptc compiled core, `run_external_core_compiler`
stage), a TS core module can only survive dispatches that allocate NOTHING
on the compiled side:

- **Stable shape (proven)**: void message arms whose update returns the
  committed root unchanged; a model carrying only numbers; no `Cmd`
  issuance at all.
- **Everything else corrupts**: `Cmd.request`/`Cmd.host` commands, routed
  (second-cycle) dispatches, tracked model writes (`{ ...model, x }`,
  literal model objects), enum-in-model slots, `Uint8Array` payload
  reads/writes.

The Zig mirror host (ts_core_main.zig + staged core.zig) is unaffected;
all crypto/envelope work lives there.

## Evidence trail (bisect order)

1. **Enum-in-model slots trap deterministically (SC4013)**. The generated
   facade's member table (`nscfMembersPhase`) and the author module's
   literals intern strings in separate pools, so `nscfIndexPhase(value)`
   never matches. Trap: `an enum slot carries an undeclared member — the
   author module and this generated module disagree`, raised in
   `nsc_core_model_snapshot` (dispatch of the FIRST message, before any
   second cycle). No arena involved — deterministic.

2. **Routed (Cmd.request) cycles corrupt the committed root**. The compiler
   emits `coreUpdate(...) -> nscfCommit(...)` with `nscfCommitted =
   out[0]`; every object the compiled code allocates (the dispatch msg,
   the command bytes sink, model literals) lives in the scriptc frame
   arena and is freed at cycle end (`frameReset` in finishCycle). A
   second cycle reuses the freed block where the committed root stood:

   - with a `pingCount: 0` (integer-classified) model the next snapshot
     traps: `an integer slot carries a non-integer or out-of-range value —
     the i64 encoding has no honest bytes for it` (SC4013);
   - with f64-classified slots the read returns garbage doubles
     (e.g. `5.3e-311` instead of `7.5`);
   - with `Uint8Array`-carrying snapshots: `scr_bytes_get` on
     `b->len=0x1cb3390, b->data=0x31` (reused/freed bytes) — segfault;
   - empty-payload routed cycles: `free(): invalid size` in the second
     test of the same process (corrupted arena cascade).

3. **Cold model literals do not help**. Returning a literal object from a
   routed arm (`return { lastEcho: 7.5 }`) hoists a static object in the
   frame; the following cycle reads the reused block (garbage). The T10
   experiment (request + cold-literal arms + f64-only model) completed
   the routed cycle but read `5.3e-311`.

4. **`Cmd.host` overload surface**: the checker's `sdk/core.ts` declares
   `host(name, ...args: readonly number[])` and `host(name, payload)`;
   the scriptc compiler surface only accepts `(name, payload: Uint8Array)`
   and additionally refuses to narrow `Cmd<never>`/`Cmd<Msg>` returns
   into the facade's command union (`SC1100 passing 'unknown' values ...
   is not supported yet`). `Cmd.request` with route literals compiles but
   corrupts on the answer's routed dispatch. An empty `{}` model likewise
   breaks the compiled tuple narrowing (`SC1100`); one number slot
   restores it.

## Consequence for the vault architecture

- The vault session state lives entirely on the ZIG side of the boundary
  (vault.zig / vault_host.zig): real file I/O, real Argon2id/XChaCha20
  envelope, full op table.
- The Task 1 round trip is proven at the BINDING: the real effects-
  channel callbacks the wiring binds (`vault_host.requestFn` /
  `sendFn`, sink standing in for `feedHostResult`) echo byte-for-byte
  and reject unknown names; the app-loop test proves the stable
  dispatch/drain shape with an intact model.
- Task 3 (CRUD/UI, next session) must observe host-side results without
  routed dispatches: UI scalars written once at boot, or a Zig-owned
  channel feeding the number slots the lane can carry.