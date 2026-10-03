import { it, expect } from "vitest";
import { AsyncGate } from "./async-gate";
it("accepts an opt-out intent even while a folder dialog is pending", () => {
  const gate = new AsyncGate();
  const folder = gate.beginMutation();
  const off = gate.beginMutation();
  expect(gate.pending).toBe(2);
  expect(gate.isLatest(off)).toBe(true);
  expect(gate.isLatest(folder)).toBe(false);
  gate.finishMutation();
  gate.finishMutation();
  expect(gate.accepts(off)).toBe(true);
});
it("rejects an in-flight snapshot captured before sharing was disabled", () => {
  const gate = new AsyncGate();
  const read = gate.epoch;
  const off = gate.beginMutation();
  expect(gate.accepts(read)).toBe(false);
  gate.finishMutation();
  expect(gate.accepts(read)).toBe(false);
  expect(gate.accepts(off)).toBe(true);
});
