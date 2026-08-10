// Task 4: acceptance oracles for the vault session state machine.
// Runs via Native SDK ts_run so src/core.ts can import @native-sdk/core.
import assert from "node:assert/strict";
import { initialModel, update } from "../src/core.ts";

function ascii(text) {
  return new Uint8Array([...text].map((ch) => ch.charCodeAt(0)));
}

function frameFields(fields) {
  let total = 1;
  for (const field of fields) total += 4 + field.length;
  const out = new Uint8Array(total);
  out[0] = fields.length;
  const dv = new DataView(out.buffer);
  let off = 1;
  for (const field of fields) {
    dv.setUint32(off, field.length, false);
    off += 4;
    out.set(field, off);
    off += field.length;
  }
  return out;
}

function bytesEq(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

function assertBytesEq(actual, expected, label) {
  assert.ok(bytesEq(actual, expected), `${label}: expected ${fmtBytes(expected)} got ${fmtBytes(actual)}`);
}

function fmtBytes(bytes) {
  return `[${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join(" ")}]`;
}

const EMPTY = new Uint8Array(0);

/** @type {import("../src/core.ts").Model} */
let model = initialModel();
/** @type {unknown[]} */
let recordedCmds = [];

function resetHarness() {
  model = initialModel();
  recordedCmds = [];
}

function dispatch(msg) {
  const result = update(model, msg);
  if (Array.isArray(result)) {
    model = result[0];
    recordedCmds.push(result[1]);
  } else {
    model = result;
  }
  return model;
}

function hostAnswer(msg) {
  return dispatch(msg);
}

function assertPhase(phase) {
  assert.equal(model.phase, phase, `phase expected ${phase}`);
}

function assertPayloadEmpty() {
  assert.equal(model.payload.length, 0, "payload expected empty");
}

function assertNoCmds() {
  assert.equal(recordedCmds.length, 0, "expected no commands");
}

function assertOneRequest(name, payload) {
  assert.equal(recordedCmds.length, 1, "expected one command");
  const cmd = recordedCmds[0];
  assert.equal(cmd.op, "request", "expected request command");
  assert.equal(cmd.name, name, "request name");
  assertBytesEq(cmd.payload, payload, "request payload");
}

function assertOneHost(name) {
  assert.equal(recordedCmds.length, 1, "expected one command");
  const cmd = recordedCmds[0];
  assert.equal(cmd.op, "host_bytes", `expected host command for ${name}`);
  assert.equal(cmd.name, name, "host name");
}

function modelContainsBytes(seq) {
  if (seq.length === 0) return false;
  const walk = (value) => {
    if (value instanceof Uint8Array) {
      for (let i = 0; i <= value.length - seq.length; i++) {
        let ok = true;
        for (let j = 0; j < seq.length; j++) {
          if (value[i + j] !== seq[j]) ok = false;
        }
        if (ok) return true;
      }
      return false;
    }
    if (typeof value === "object" && value !== null) {
      for (const key of Object.keys(value)) {
        if (walk(value[key])) return true;
      }
    }
    return false;
  };
  return walk(model);
}

const tests = [
  {
    name: "create unlocks",
    run() {
      resetHarness();
      const pw = ascii("secret");
      dispatch({ kind: "create_attempt", password: pw });
      assertOneRequest("vault.create", frameFields([pw]));
      recordedCmds = [];
      hostAnswer({ kind: "created", note: EMPTY });
      assertPhase("unlocked");
      assertPayloadEmpty();
    },
  },
  {
    name: "save then lock then unlock restores payload",
    run() {
      resetHarness();
      const pw = ascii("secret");
      const payload = ascii("payload-bytes");
      dispatch({ kind: "create_attempt", password: pw });
      recordedCmds = [];
      hostAnswer({ kind: "created", note: EMPTY });
      dispatch({ kind: "save_attempt", payload });
      assertOneRequest("vault.save", frameFields([payload]));
      recordedCmds = [];
      hostAnswer({ kind: "saved", note: EMPTY });
      dispatch({ kind: "lock" });
      assertOneHost("vault.lock");
      assertPhase("locked");
      assertPayloadEmpty();
      recordedCmds = [];
      dispatch({ kind: "unlock_attempt", password: pw });
      assertOneRequest("vault.unlock", frameFields([pw]));
      recordedCmds = [];
      hostAnswer({ kind: "unlocked", payload });
      assertPhase("unlocked");
      assertBytesEq(model.payload, payload, "restored payload");
    },
  },
  {
    name: "wrong password keeps locked",
    run() {
      resetHarness();
      const pw = ascii("secret");
      dispatch({ kind: "create_attempt", password: pw });
      recordedCmds = [];
      hostAnswer({ kind: "created", note: EMPTY });
      dispatch({ kind: "lock" });
      recordedCmds = [];
      dispatch({ kind: "unlock_attempt", password: ascii("bad") });
      assertOneRequest("vault.unlock", frameFields([ascii("bad")]));
      recordedCmds = [];
      hostAnswer({ kind: "unlock_failed", reason: ascii("wrong_password") });
      assertPhase("locked");
      assertBytesEq(model.lastError, ascii("wrong_password"), "error code");
    },
  },
  {
    name: "change password keeps session",
    run() {
      resetHarness();
      const cur = ascii("cur");
      const next = ascii("next");
      dispatch({ kind: "create_attempt", password: cur });
      recordedCmds = [];
      hostAnswer({ kind: "created", note: EMPTY });
      dispatch({ kind: "change_attempt", current: cur, next });
      assertOneRequest("vault.change_password", frameFields([cur, next]));
      recordedCmds = [];
      hostAnswer({ kind: "changed", note: EMPTY });
      assertPhase("unlocked");
    },
  },
  {
    name: "save while locked issues no command",
    run() {
      resetHarness();
      dispatch({ kind: "lock" });
      recordedCmds = [];
      dispatch({ kind: "save_attempt", payload: ascii("x") });
      assertNoCmds();
      assertBytesEq(model.lastError, ascii("locked"), "locked save error");
    },
  },
  {
    name: "change while locked issues no command",
    run() {
      resetHarness();
      dispatch({ kind: "lock" });
      recordedCmds = [];
      dispatch({ kind: "change_attempt", current: ascii("a"), next: ascii("b") });
      assertNoCmds();
      assertBytesEq(model.lastError, ascii("locked"), "locked change error");
    },
  },
  {
    name: "lock is idempotent",
    run() {
      resetHarness();
      dispatch({ kind: "lock" });
      assertOneHost("vault.lock");
      recordedCmds = [];
      dispatch({ kind: "lock" });
      assertNoCmds();
      assertPhase("locked");
      dispatch({ kind: "lock" });
      assertNoCmds();
      assertPhase("locked");
    },
  },
  {
    name: "password never enters the model",
    run() {
      resetHarness();
      const pw = ascii("never-in-model");
      dispatch({ kind: "create_attempt", password: pw });
      assert.ok(!modelContainsBytes(pw), "create password leaked into model");
      recordedCmds = [];
      hostAnswer({ kind: "created", note: EMPTY });
      assert.ok(!modelContainsBytes(pw), "create password leaked after created");
      const cur = ascii("cur-pass");
      const next = ascii("next-pass");
      dispatch({ kind: "change_attempt", current: cur, next });
      assert.ok(!modelContainsBytes(cur), "change current leaked");
      assert.ok(!modelContainsBytes(next), "change next leaked");
    },
  },
  {
    name: "simulation sweep invariants hold",
    run() {
      runSimulationSweep(200, 0x4b414b55);
    },
  },
];

const KNOWN_ERROR_CODES = [
  "bad_request",
  "unknown",
  "not_found",
  "wrong_password",
  "corrupt",
  "unsupported_version",
  "already_exists",
  "locked",
  "io_failed",
  "out_of_memory",
  "params_invalid",
  "payload_too_large",
].map(ascii);

function parseFrameFields(payload) {
  const n = payload[0];
  const fields = [];
  let off = 1;
  for (let i = 0; i < n; i++) {
    const len =
      (payload[off] << 24) | (payload[off + 1] << 16) | (payload[off + 2] << 8) | payload[off + 3];
    off += 4;
    fields.push(payload.subarray(off, off + len));
    off += len;
  }
  return fields;
}

function isKnownError(bytes) {
  if (bytes.length === 0) return true;
  return KNOWN_ERROR_CODES.some((code) => bytesEq(code, bytes));
}

function mulberry32(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function randomAscii(rng, len) {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  let text = "";
  for (let i = 0; i < len; i++) {
    text += alphabet[Math.floor(rng() * alphabet.length)];
  }
  return ascii(text);
}

function runSimulationSweep(steps, seed) {
  resetHarness();
  const rng = mulberry32(seed);
  const sim = {
    vaultExists: false,
    password: EMPTY,
    storedPayload: EMPTY,
    lastSuccess: null,
    locksSinceSuccess: 0,
  };
  const log = [];

  function onSuccess(kind) {
    sim.lastSuccess = kind;
    sim.locksSinceSuccess = 0;
  }

  function shouldBeUnlocked() {
    return sim.lastSuccess !== null && sim.locksSinceSuccess === 0;
  }

  function checkInvariants(stepLabel) {
    const phases = new Set(["fresh", "locked", "unlocked"]);
    if (!phases.has(model.phase)) {
      throw new Error(`${stepLabel}: invalid phase ${model.phase}\n${formatLog(log)}`);
    }
    const unlocked = model.phase === "unlocked";
    if (unlocked !== shouldBeUnlocked()) {
      throw new Error(
        `${stepLabel}: phase/unlock mismatch phase=${model.phase} lastSuccess=${sim.lastSuccess} locksSinceSuccess=${sim.locksSinceSuccess}\n${formatLog(log)}`,
      );
    }
    if (!isKnownError(model.lastError)) {
      throw new Error(
        `${stepLabel}: unknown lastError ${fmtAscii(model.lastError)}\n${formatLog(log)}`,
      );
    }
    if (model.phase === "locked" && model.payload.length !== 0) {
      throw new Error(`${stepLabel}: locked with non-empty payload\n${formatLog(log)}`);
    }
  }

  function answerCmd(cmd) {
    if (cmd.op === "host_bytes") return;
    const fields = parseFrameFields(cmd.payload);
    if (cmd.name === "vault.create") {
      const pw = fields[0] ?? EMPTY;
      if (sim.vaultExists) {
        hostAnswer({ kind: "create_failed", reason: ascii("already_exists") });
        return;
      }
      sim.vaultExists = true;
      sim.password = pw;
      sim.storedPayload = EMPTY;
      hostAnswer({ kind: "created", note: EMPTY });
      onSuccess("create");
      return;
    }
    if (cmd.name === "vault.unlock") {
      const pw = fields[0] ?? EMPTY;
      if (!bytesEq(pw, sim.password)) {
        hostAnswer({ kind: "unlock_failed", reason: ascii("wrong_password") });
        return;
      }
      hostAnswer({ kind: "unlocked", payload: sim.storedPayload });
      onSuccess("unlock");
      return;
    }
    if (cmd.name === "vault.save") {
      sim.storedPayload = fields[0] ?? EMPTY;
      hostAnswer({ kind: "saved", note: EMPTY });
      return;
    }
    if (cmd.name === "vault.change_password") {
      const cur = fields[0] ?? EMPTY;
      const next = fields[1] ?? EMPTY;
      if (!bytesEq(cur, sim.password)) {
        hostAnswer({ kind: "change_failed", reason: ascii("wrong_password") });
        return;
      }
      sim.password = next;
      hostAnswer({ kind: "changed", note: EMPTY });
      onSuccess("change");
    }
  }

  function pickOp() {
    const roll = rng();
    if (!sim.vaultExists) {
      return roll < 0.7
        ? { kind: "create_attempt", password: randomAscii(rng, 4 + Math.floor(rng() * 8)) }
        : { kind: "lock" };
    }
    if (model.phase === "unlocked") {
      if (roll < 0.2) return { kind: "save_attempt", payload: randomAscii(rng, Math.floor(rng() * 32)) };
      if (roll < 0.35) return { kind: "lock" };
      if (roll < 0.5) {
        const next = randomAscii(rng, 4 + Math.floor(rng() * 8));
        return { kind: "change_attempt", current: sim.password, next };
      }
      if (roll < 0.65) return { kind: "lock" };
      return { kind: "save_attempt", payload: randomAscii(rng, 1 + Math.floor(rng() * 16)) };
    }
    if (roll < 0.55) {
      const useGood = rng() < 0.7;
      const pw = useGood ? sim.password : randomAscii(rng, 4 + Math.floor(rng() * 8));
      return { kind: "unlock_attempt", password: pw };
    }
    if (roll < 0.75) return { kind: "create_attempt", password: randomAscii(rng, 4 + Math.floor(rng() * 8)) };
    if (roll < 0.9) return { kind: "save_attempt", payload: randomAscii(rng, 4) };
    return { kind: "change_attempt", current: randomAscii(rng, 4), next: randomAscii(rng, 4) };
  }

  for (let step = 0; step < steps; step++) {
    const msg = pickOp();
    const label = `step ${step}: ${msg.kind}`;
    log.push(label);
    const phaseBefore = model.phase;
    dispatch(msg);
    for (const cmd of recordedCmds) {
      if (cmd.op === "request" && cmd.name === "vault.save" && phaseBefore !== "unlocked") {
        throw new Error(`${label}: vault.save issued while phase=${phaseBefore}\n${formatLog(log)}`);
      }
      answerCmd(cmd);
    }
    if (msg.kind === "lock" && model.phase === "locked" && phaseBefore !== "locked") {
      sim.locksSinceSuccess += 1;
    }
    recordedCmds = [];
    checkInvariants(label);
  }
}

function fmtAscii(bytes) {
  return `"${String.fromCharCode(...bytes)}"`;
}

function formatLog(log) {
  return `sequence:\n${log.join("\n")}`;
}

let failed = 0;
for (const test of tests) {
  try {
    test.run();
    console.log(`PASS ${test.name}`);
  } catch (err) {
    failed += 1;
    console.error(`FAIL ${test.name}`);
    console.error(err instanceof Error ? err.message : err);
  }
}

if (failed > 0) {
  console.error(`${failed}/${tests.length} oracle(s) failed`);
  process.exit(1);
}

console.log(`ALL ${tests.length} ORACLES PASS`);
