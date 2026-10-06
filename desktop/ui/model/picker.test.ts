import { describe, expect, it } from "vitest";
import { CODING_TOOLS, cohort, toolChip, toolLabel, type Metric } from "../metrics";
import { pickerAccessibleLabel, pickerLabel, pickerTool } from "../components/Header";
import { buildDashboard } from "./dashboard";
import { SOURCE_TITLES } from "./format";
import { RECENT_MODEL_LIMIT, recentModelRows, toolModelHint } from "./picker";

const NOW = Date.parse("2026-10-04T12:00:00Z");
const turn = (id: string, minutesAgo: number, p: Partial<Metric> = {}): Metric => ({
  id,
  completedAt: new Date(NOW - minutesAgo * 60000).toISOString(),
  model: "gpt-5.5",
  provider: "openai",
  clientVersion: "1",
  reasoningEffort: "high",
  outputTokens: 600,
  durationSeconds: 10,
  codexTTFTSeconds: 2,
  turnThroughputTPS: 60,
  responseOutputTokens: 600,
  responseDurationSeconds: 6,
  responseCount: 3,
  ...p,
});
const claude = (id: string, minutesAgo: number, p: Partial<Metric> = {}) =>
  turn(id, minutesAgo, {
    client: "claude-code",
    model: "claude-opus-5-5",
    provider: "anthropic",
    parserVersion: "claude-transcript-v4",
    metricVersion: "claude-observed-turn-v1",
    sourceKind: "primary",
    codexTTFTSeconds: null,
    ...p,
  });
const subagent = (id: string, minutesAgo: number) =>
  claude(id, minutesAgo, { metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent" });
const dashboard = (records: Metric[], over = {}) =>
  buildDashboard({
    records,
    selection: "auto",
    days: 1,
    tool: "all",
    provider: "all",
    now: NOW,
    sort: "recent",
    ...over,
  });
const recent = (records: Metric[]) => recentModelRows(dashboard(records).cohorts);

describe("recent models", () => {
  it("merges rows that differ only by client version and keeps the newest", () => {
    const rows = recent([
      turn("old", 120, { clientVersion: "1" }),
      turn("new", 10, { clientVersion: "2" }),
      turn("mid", 60, { clientVersion: "1.5", parserVersion: "codex-rollout-v2" }),
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0].row.key).toBe(cohort(turn("new", 10, { clientVersion: "2" })));
    expect(rows[0].title).toBe("gpt-5.5 · high");
  });
  it("keeps at most five, newest first", () => {
    const records = Array.from({ length: 7 }, (_, i) => turn(`t${i}`, 10 + i * 10, { model: `model-${i}` }));
    const rows = recent(records);
    expect(RECENT_MODEL_LIMIT).toBe(5);
    expect(rows.map((r) => r.row.sample.model)).toEqual(["model-0", "model-1", "model-2", "model-3", "model-4"]);
  });
  it("leaves out rows without a model", () => {
    const rows = recent([turn("u", 1, { model: null }), turn("k", 30)]);
    expect(rows.map((r) => r.row.sample.id)).toEqual(["k"]);
  });
  it("names the provider only when two rows would read the same", () => {
    const rows = recent([
      claude("a", 10),
      claude("b", 20, { provider: "amazon-bedrock" }),
      turn("c", 30, { model: "gpt-5.4" }),
    ]);
    expect(rows.map((r) => r.title)).toEqual([
      "claude-opus-5-5 · high · Anthropic",
      "claude-opus-5-5 · high · Amazon Bedrock",
      "gpt-5.4 · high",
    ]);
  });
  it("tells different coding tools apart by their chip, not the provider", () => {
    const rows = recent([turn("a", 10), turn("b", 20, { client: "grok-build", provider: "openai" })]);
    expect(rows.map((r) => r.title)).toEqual(["gpt-5.5 · high", "gpt-5.5 · high · Work turn"]);
  });
  it("keeps subagent rows separate from the primary ones", () => {
    const rows = recent([claude("p", 10), subagent("s", 20)]);
    expect(rows.map((r) => r.title)).toEqual(["claude-opus-5-5 · high", "claude-opus-5-5 · high · Subagent"]);
  });
  it("treats an unknown effort the same however it is recorded", () => {
    const rows = recent([turn("a", 10, { reasoningEffort: null }), turn("b", 20, { reasoningEffort: "unknown" })]);
    expect(rows).toHaveLength(1);
    expect(rows[0].title).toBe("gpt-5.5 · effort unknown");
  });
});

describe("tool hints", () => {
  const records = [
    claude("c-new", 5, { reasoningEffort: "medium", model: "claude-opus-5-5", responseOutputTokens: null }),
    claude("c-resp", 30, { model: "claude-sonnet-5", reasoningEffort: "high" }),
    turn("x", 10),
  ];
  it("uses the newest turn with response data of that tool", () => {
    const d = dashboard(records);
    expect(toolModelHint(d, "claude-code")).toBe("claude-sonnet-5 · high");
    expect(toolModelHint(d, "codex")).toBe("gpt-5.5 · high");
  });
  it("has no hint for a tool without a model or without turns", () => {
    expect(toolModelHint(dashboard([turn("u", 5, { model: null })]), "codex")).toBeNull();
    expect(toolModelHint(dashboard([turn("x", 5)]), "grok-build")).toBeNull();
  });
  it("leaves the effort out when unknown", () => {
    expect(toolModelHint(dashboard([turn("x", 5, { reasoningEffort: "unknown" })]), "codex")).toBe("gpt-5.5");
  });
  it("follows the hero when Auto already runs in that tool", () => {
    const active = { model: "claude-opus-5-5", provider: "anthropic" };
    const d = dashboard(records, { selection: "auto:claude-code", active: null });
    expect(d.activeKey).toEqual({ model: "claude-sonnet-5", provider: "anthropic" });
    expect(toolModelHint(d, "claude-code")).toBe("claude-sonnet-5 · high");
    const live = dashboard(records, {
      selection: "auto:claude-code",
      active,
      live: [
        {
          id: "l",
          completedAt: new Date(NOW - 30000).toISOString(),
          model: "claude-opus-5-5",
          provider: "anthropic",
          client: "claude-code",
          sourceKind: "primary",
          metricVersion: "response-v1",
          reasoningEffort: "medium",
          outputTokens: 500,
          durationSeconds: 5,
        },
      ],
    });
    expect(live.activeKey?.model).toBe("claude-opus-5-5");
    expect(toolModelHint(live, "claude-code")).toBe("claude-opus-5-5 · medium");
    // Other tools keep their own latest model.
    expect(toolModelHint(live, "codex")).toBe("gpt-5.5 · high");
  });
});

describe("coding tool table", () => {
  it("derives titles and chips from one table", () => {
    expect(SOURCE_TITLES).toEqual({
      codex: "Codex",
      "claude-code": "Claude Code",
      "grok-build": "Grok Build",
      antigravity: "Antigravity",
      opencode: "OpenCode",
    });
    expect(Object.keys(CODING_TOOLS)).toEqual(Object.keys(SOURCE_TITLES));
    expect(["codex", "claude-code", "grok-build", "antigravity", "opencode"].map(toolChip)).toEqual(["CX", "CC", "GB", "AG", "OC"]);
    expect(toolLabel("claude-code")).toBe("Claude Code");
    expect(toolLabel("other")).toBe("Coding tool");
  });
  it("falls back to the first two letters of an unknown tool", () => {
    expect(toolChip("gemini-cli")).toBe("GE");
    expect(toolChip("x")).toBe("X");
  });
});

describe("picker trigger label", () => {
  it("keeps plain Auto without a chip", () => {
    const d = dashboard([]);
    expect(pickerLabel(d)).toBe("Auto (most active)");
    expect(pickerTool(d)).toBeNull();
    expect(pickerLabel(dashboard([turn("x", 5)]))).toBe("Auto · gpt-5.5");
  });
  it("moves the coding tool of Auto into the chip but still names it for screen readers", () => {
    const d = dashboard([claude("c", 5)], { selection: "auto:claude-code" });
    expect(pickerLabel(d)).toBe("Auto · claude-opus-5-5");
    expect(pickerTool(d)).toBe("claude-code");
    expect(pickerAccessibleLabel(d)).toBe("Auto in Claude Code · claude-opus-5-5");
    const empty = dashboard([turn("x", 5)], { selection: "auto:claude-code" });
    expect(empty.activeKey).toBeNull();
    expect(pickerLabel(empty)).toBe("Auto");
    expect(pickerAccessibleLabel(empty)).toBe("Auto in Claude Code");
  });
  it("shows an exact cohort with its tool as the chip", () => {
    const record = claude("c", 5, { clientVersion: "2.1.0" });
    const d = dashboard([record, claude("d", 6, { clientVersion: "2.0.0" })], { selection: cohort(record) });
    expect(pickerTool(d)).toBe("claude-code");
    expect(pickerLabel(d)).toBe("claude-opus-5-5 · high · v2.1.0");
    expect(pickerAccessibleLabel(d)).toBe("Claude Code · claude-opus-5-5 · high · v2.1.0");
  });
  it("leaves pins and compare mode unchanged", () => {
    const records = [claude("c", 5)];
    const pin = dashboard(records, { selection: 'model:["claude-opus-5-5","anthropic"]' });
    expect(pickerLabel(pin)).toBe("claude-opus-5-5");
    expect(pickerTool(pin)).toBeNull();
    expect(pickerAccessibleLabel(pin)).toBe("claude-opus-5-5");
    const all = dashboard(records, { selection: "all" });
    expect(pickerLabel(all)).toBe("All models");
    expect(pickerAccessibleLabel(all)).toBe("All models");
  });
});
