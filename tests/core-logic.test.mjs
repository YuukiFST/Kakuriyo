// Lane-safe core oracles — vault session logic lives in Zig (app_controller).
import assert from "node:assert/strict";
import { initialModel, update } from "../src/core.ts";

function dispatch(model, msg) {
  return update(model, msg);
}

function resetHarness() {
  return initialModel();
}

assert.equal(dispatch(resetHarness(), { kind: "unlock_press" }).phase, 0);
assert.equal(dispatch(resetHarness(), { kind: "tick" }).treeEpoch, 0);

const m0 = initialModel();
assert.equal(m0.vimMotion, 1);
assert.equal(m0.phase, 0);

console.log("PASS identity core oracles");
console.log("ALL CORE ORACLES PASS");
