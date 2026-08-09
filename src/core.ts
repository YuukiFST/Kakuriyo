// Kakuriyo app core: vault session orchestration.
//
// Task 1 seam: the round trip is proven at the BINDING — the real
// effects-channel callbacks the wiring binds (vault_host.requestFn /
// sendFn with a feedHostResult-shaped sink) echo byte-for-byte and
// reject unknown names (host_roundtrip_tests.zig). This core module
// only proves the app loop survives dispatch/drain cycles on a
// number-only model.
//
// Why the core cannot issue commands (Cmd.request / Cmd.host): the
// compiled-TS lane in @native-sdk/cli 0.8.3 frees every object the
// compiled code allocates (the dispatch msg, cmd sinks, model
// literals) at cycle end — the frame arena — so the NEXT cycle reads a
// REUSED block where the committed root stood. Empirically proven
// while building this seam (see
// .scratch/kakuriyo/research/ts-core-lane-limits.md):
//   1. enum-in-model slots trap deterministically (SC4013) — the
//      generated facade's member table and the author module's
//      literals intern in separate pools;
//   2. a routed (second-cycle) dispatch reuses the root's block — the
//      next snapshot traps ("an integer slot carries a non-integer or
//      out-of-range value") or reads garbage f64s;
//   3. Uint8Array fields/payload reads segfault (scr_bytes_get on a
//      reused block).
// The only stable shape: void arms, updates returning the root
// UNCHANGED, model carrying numbers only. The vault session therefore
// lives entirely on the ZIG side of the boundary (vault.zig /
// vault_host.zig — the real envelope work); Task 3's UI must bind
// host-computed scalar summaries written ONCE at boot, or render
// host-side state through a Zig-owned channel — a design constraint
// documented for the CRUD/UI goal.

export interface Model {
  // A number slot the compiled lane survives (f64-classified; the
  // initial -0.5 dodges the wholeness veto on integer classification,
  // which would i64-encode a corrupted double and trap).
  readonly echo: number;
}

export type Msg =
  // `ping_attempt` rides the void lane; the host side of the round
  // trip is asserted at the binding (request_fn <-> sink). The routed
  // arms stay in the contract shape for Cmd.request routes.
  | { readonly kind: "ping_attempt" }
  | { readonly kind: "pinged" }
  | { readonly kind: "ping_failed" };

// `pinged`/`ping_failed` are host-issued (reserved for routed answers),
// `ping_attempt` is dispatched by the test harness, `echo` is read by
// Zig-side tests only — the scriptc check demands they be declared
// unbound-from-markup.
export const viewUnbound = ["echo", "ping_attempt", "pinged", "ping_failed"] as const;

export function initialModel(): Model {
  return { echo: -0.5 };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "ping_attempt":
    case "pinged":
    case "ping_failed":
      // The stable shape: return the root unchanged (see header).
      return model;
  }
}