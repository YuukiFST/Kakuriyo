// Kakuriyo app core: vault session orchestration.
//
// Node harness (`tests/core-logic.test.mjs`) exercises the full state
// machine outside the compiled lane. The scriptc compiled lane in
// @native-sdk/cli 0.8.3 still cannot sustain Cmd.request / allocating
// updates at runtime — see .scratch/kakuriyo/research/ts-core-lane-limits.md.
// Binding-level round trips remain proven in host_roundtrip_tests.zig.

import { Cmd, asciiBytes } from "@native-sdk/core";

export type Phase = "fresh" | "locked" | "unlocked";

export interface Model {
  readonly phase: Phase;
  readonly payload: Uint8Array;
  readonly lastError: Uint8Array;
  readonly lastPing: Uint8Array;
}

export type Msg =
  | { readonly kind: "create_attempt"; readonly password: Uint8Array }
  | { readonly kind: "created"; readonly note: Uint8Array }
  | { readonly kind: "create_failed"; readonly reason: Uint8Array }
  | { readonly kind: "unlock_attempt"; readonly password: Uint8Array }
  | { readonly kind: "unlocked"; readonly payload: Uint8Array }
  | { readonly kind: "unlock_failed"; readonly reason: Uint8Array }
  | { readonly kind: "save_attempt"; readonly payload: Uint8Array }
  | { readonly kind: "saved"; readonly note: Uint8Array }
  | { readonly kind: "save_failed"; readonly reason: Uint8Array }
  | { readonly kind: "change_attempt"; readonly current: Uint8Array; readonly next: Uint8Array }
  | { readonly kind: "changed"; readonly note: Uint8Array }
  | { readonly kind: "change_failed"; readonly reason: Uint8Array }
  | { readonly kind: "lock" }
  | { readonly kind: "ping_attempt"; readonly payload: Uint8Array }
  | { readonly kind: "pinged"; readonly payload: Uint8Array }
  | { readonly kind: "ping_failed"; readonly reason: Uint8Array };

export const viewUnbound = [
  "created",
  "create_failed",
  "unlocked",
  "unlock_failed",
  "saved",
  "save_failed",
  "changed",
  "change_failed",
  "pinged",
  "ping_failed",
] as const;

const EMPTY = new Uint8Array(0);
const LOCKED = asciiBytes("locked");

function frameFields(fields: readonly Uint8Array[]): Uint8Array {
  let total = 1;
  for (const field of fields) total += 4 + field.length;
  const out = new Uint8Array(total);
  out[0] = fields.length;
  let off = 1;
  for (const field of fields) {
    out[off] = (field.length >>> 24) & 0xff;
    out[off + 1] = (field.length >>> 16) & 0xff;
    out[off + 2] = (field.length >>> 8) & 0xff;
    out[off + 3] = field.length & 0xff;
    off += 4;
    out.set(field, off);
    off += field.length;
  }
  return out;
}

export function initialModel(): Model {
  return { phase: "fresh", payload: EMPTY, lastError: EMPTY, lastPing: EMPTY };
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "create_attempt":
      return [
        model,
        Cmd.request("vault.create", frameFields([msg.password]), {
          ok: "created",
          err: "create_failed",
        }),
      ];

    case "created":
      return { ...model, phase: "unlocked", payload: EMPTY, lastError: EMPTY };

    case "create_failed":
      return { ...model, lastError: msg.reason };

    case "unlock_attempt":
      return [
        model,
        Cmd.request("vault.unlock", frameFields([msg.password]), {
          ok: "unlocked",
          err: "unlock_failed",
        }),
      ];

    case "unlocked":
      return { ...model, phase: "unlocked", payload: msg.payload, lastError: EMPTY };

    case "unlock_failed":
      return { ...model, lastError: msg.reason };

    case "save_attempt":
      if (model.phase !== "unlocked") {
        return { ...model, lastError: LOCKED };
      }
      return [
        model,
        Cmd.request("vault.save", frameFields([msg.payload]), {
          ok: "saved",
          err: "save_failed",
        }),
      ];

    case "saved":
      return { ...model, lastError: EMPTY };

    case "save_failed":
      return { ...model, lastError: msg.reason };

    case "change_attempt":
      if (model.phase !== "unlocked") {
        return { ...model, lastError: LOCKED };
      }
      return [
        model,
        Cmd.request("vault.change_password", frameFields([msg.current, msg.next]), {
          ok: "changed",
          err: "change_failed",
        }),
      ];

    case "changed":
      return { ...model, lastError: EMPTY };

    case "change_failed":
      return { ...model, lastError: msg.reason };

    case "lock":
      if (model.phase === "locked") {
        return model;
      }
      return [
        { ...model, phase: "locked", payload: EMPTY, lastError: EMPTY },
        Cmd.host("vault.lock", EMPTY),
      ];

    case "ping_attempt":
    case "pinged":
    case "ping_failed":
      return model;
  }
}
