import { describe, expect, it } from "vitest";
import {
  EFFICIENCY_MIN_BUCKET_TURNS,
  EFFICIENCY_MIN_TURNS,
  efficiencyBuckets,
  efficiencyDashboard,
  efficiencyKey,
  efficiencyReference,
  efficiencyRows,
  efficiencyScaleMax,
  eligibleTotal,
  indicatorOf,
  percentile,
  sortEfficiencyRows,
  totalTokens,
} from "./efficiency";
import { DAY, type Metric } from "./metrics";
import { previewRecords } from "./store/preview";

const NOW = Date.parse("2026-10-04T12:00:00Z");
const turn = (id: string, minutesAgo: number, p: Partial<Metric> = {}): Metric => ({
  id,
  completedAt: new Date(NOW - minutesAgo * 60000).toISOString(),
  model: "model-a",
  provider: "openai",
  clientVersion: "1",
  client: "codex",
  reasoningEffort: "high",
  sourceKind: "primary",
  outputTokens: 1000,
  delegatedOutputTokens: 0,
  durationSeconds: 20,
  codexTTFTSeconds: 2,
  turnThroughputTPS: 50,
  ...p,
});
/** `count` eligible turns of one model and effort with the given total, spread over the last day. */
const many = (model: string, total: number, count = 20, p: Partial<Metric> = {}) =>
  Array.from({ length: count }, (_, i) =>
    turn(`${model}-${i}`, 10 + i * 30, { model, outputTokens: total, ...p }),
  );

describe("eligibility", () => {
  it("totals output and delegated tokens and needs the delegated value to be final", () => {
    expect(totalTokens(turn("a", 1, { outputTokens: 900, delegatedOutputTokens: 300 }))).toBe(1200);
    expect(totalTokens(turn("a", 1, { delegatedOutputTokens: null }))).toBeNull();
    expect(totalTokens(turn("a", 1, { delegatedOutputTokens: undefined }))).toBeNull();
    expect(totalTokens(turn("a", 1, { delegatedOutputTokens: -1 }))).toBeNull();
  });
  it("keeps primary turns of a known model and tool with at least 200 total tokens", () => {
    expect(eligibleTotal(turn("a", 1))).toBe(1000);
    expect(eligibleTotal(turn("a", 1, { outputTokens: 199, delegatedOutputTokens: 0 }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { outputTokens: 100, delegatedOutputTokens: 100 }))).toBe(200);
    expect(eligibleTotal(turn("a", 1, { sourceKind: "subagent", delegatedOutputTokens: null }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { sourceKind: undefined }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { model: null }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { client: "unknown-tool" }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { client: "antigravity" }))).toBe(1000);
    expect(eligibleTotal(turn("a", 1, { client: "opencode" }))).toBe(1000);
    expect(eligibleTotal(turn("a", 1, { client: "opencode", delegatedOutputTokens: null }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { client: "kimi-code" }))).toBe(1000);
    expect(eligibleTotal(turn("a", 1, { client: "kimi-code", delegatedOutputTokens: null }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { client: "antigravity", delegatedOutputTokens: null }))).toBeNull();
    expect(eligibleTotal(turn("a", 1, { delegatedOutputTokens: null }))).toBeNull();
  });
  it("groups by model and effort, treating a missing effort as unknown", () => {
    expect(efficiencyKey(turn("a", 1, { reasoningEffort: null }))).toBe(
      efficiencyKey(turn("b", 1, { reasoningEffort: "unknown" })),
    );
    expect(efficiencyKey(turn("a", 1))).not.toBe(efficiencyKey(turn("b", 1, { reasoningEffort: "low" })));
    // Tools, providers and versions combine.
    expect(efficiencyKey(turn("a", 1))).toBe(
      efficiencyKey(turn("b", 1, { client: "claude-code", provider: "anthropic", clientVersion: "9" })),
    );
  });
});

describe("percentile", () => {
  it("interpolates between neighbours", () => {
    expect(percentile([], 0.5)).toBeNull();
    expect(percentile([5], 0.25)).toBe(5);
    expect(percentile([1, 2, 3, 4], 0.5)).toBe(2.5);
    expect(percentile([1, 2, 3, 4, 5], 0.25)).toBe(2);
    expect(percentile([1, 2, 3, 4, 5], 0.75)).toBe(4);
  });
});

describe("reference and indicator", () => {
  it("needs 20 eligible turns overall", () => {
    expect(efficiencyReference(many("m", 1000, EFFICIENCY_MIN_TURNS - 1))).toBeNull();
    expect(efficiencyReference(many("m", 1000, EFFICIENCY_MIN_TURNS))).toEqual({ median: 1000, turns: 20 });
    expect(efficiencyReference([])).toBeNull();
  });
  it("ignores ineligible turns", () => {
    const records = [...many("m", 1000), turn("small", 1, { outputTokens: 50 }), turn("sub", 1, { sourceKind: "subagent", delegatedOutputTokens: null })];
    expect(efficiencyReference(records)?.turns).toBe(20);
  });
  it("rounds 100 x R / M: 100 typical, 200 half the tokens, 50 twice the tokens", () => {
    expect(indicatorOf(1000, 1000)).toBe(100);
    expect(indicatorOf(1000, 500)).toBe(200);
    expect(indicatorOf(1000, 2000)).toBe(50);
    expect(indicatorOf(1000, 630)).toBe(159);
    expect(indicatorOf(1000, 1500)).toBe(67);
  });
});

describe("rows", () => {
  const records = [...many("lean", 500), ...many("typical", 1000), ...many("heavy", 2000)];
  const reference = efficiencyReference(records);
  it("scores each model and effort against the reference over all models", () => {
    expect(reference?.median).toBe(1000);
    const rows = efficiencyRows(records, reference);
    expect(Object.fromEntries(rows.map((r) => [r.model, r.indicator]))).toEqual({
      lean: 200,
      typical: 100,
      heavy: 50,
    });
  });
  it("splits one model by reasoning effort", () => {
    const split = [...many("m", 1000, 20, { reasoningEffort: "low" }), ...many("m", 2000, 20, { reasoningEffort: "high" })];
    const rows = efficiencyRows(split, efficiencyReference(split));
    expect(rows).toHaveLength(2);
    expect(rows.find((r) => r.effort === "low")?.indicator).toBeGreaterThan(rows.find((r) => r.effort === "high")?.indicator ?? 0);
  });
  it("shows no value below 20 eligible turns, or without a reference", () => {
    const few = [...many("typical", 1000), ...many("new", 300, 19)];
    const rows = efficiencyRows(few, efficiencyReference(few));
    expect(rows.find((r) => r.model === "new")).toMatchObject({ indicator: null, turns: 19 });
    expect(rows.find((r) => r.model === "typical")?.indicator).toBe(100);
    expect(efficiencyRows(many("x", 1000, 19), null)[0].indicator).toBeNull();
  });
  it("computes detail statistics", () => {
    const rows = efficiencyRows(
      [
        ...many("d", 1000, 10, { outputTokens: 800, delegatedOutputTokens: 200, reasoningOutputTokens: 200 }),
        ...many("d", 1000, 10, { outputTokens: 1000, delegatedOutputTokens: 0, reasoningOutputTokens: null }),
      ],
      null,
    );
    const row = rows[0];
    expect(row.turns).toBe(20);
    expect(row.medianTokens).toBe(1000);
    expect(row.p25Tokens).toBe(1000);
    expect(row.p75Tokens).toBe(1000);
    // Only turns that report reasoning count: 200 / 800.
    expect(row.reasoningShare).toBeCloseTo(0.25, 9);
    // 10 x 200 delegated of 20 x 1000 total.
    expect(row.delegatedShare).toBeCloseTo(0.1, 9);
  });
  it("leaves the reasoning share empty when no turn reports it", () => {
    expect(efficiencyRows(many("n", 1000, 3), null)[0].reasoningShare).toBeNull();
  });
  it("names a provider only when the group has exactly one", () => {
    const mixed = [...many("p", 1000, 10), ...many("p", 1000, 10, { provider: "amazon-bedrock", id: "z" })];
    expect(efficiencyRows(mixed, null)[0].provider).toBeNull();
    expect(efficiencyRows(many("p", 1000, 3), null)[0].provider).toBe("openai");
  });
  it("ranks by indicator, unscored rows last, and by recency on request", () => {
    const rows = efficiencyRows([...records, ...many("new", 300, 5)], reference);
    expect(sortEfficiencyRows(rows, "efficiency").map((r) => r.model)).toEqual(["lean", "typical", "heavy", "new"]);
    expect(sortEfficiencyRows(rows, "recent")[0].latestAt).toBe(Math.max(...rows.map((r) => r.latestAt)));
  });
  it("scales bars to the largest indicator but never below the 100 tick", () => {
    const rows = efficiencyRows(records, reference);
    expect(efficiencyScaleMax(rows)).toBe(200);
    expect(efficiencyScaleMax(efficiencyRows(many("typical", 1000), reference))).toBe(100);
    expect(efficiencyScaleMax([])).toBe(100);
  });
});

describe("chart buckets", () => {
  const reference = { median: 1000, turns: 40 };
  const hourAgo = (h: number) => h * 60 + 5;
  it("needs 3 eligible turns per bucket and gaps otherwise", () => {
    const records = [
      ...Array.from({ length: EFFICIENCY_MIN_BUCKET_TURNS }, (_, i) => turn(`a${i}`, hourAgo(2) + i, { outputTokens: 500 })),
      ...Array.from({ length: EFFICIENCY_MIN_BUCKET_TURNS - 1 }, (_, i) => turn(`b${i}`, hourAgo(10) + i, { outputTokens: 500 })),
    ];
    const buckets = efficiencyBuckets(records, NOW, 1, reference, efficiencyKey(records[0]));
    expect(buckets).toHaveLength(24);
    const filled = buckets.filter((b) => b.value !== null);
    expect(filled).toHaveLength(1);
    expect(filled[0]).toMatchObject({ value: 200, count: 3 });
  });
  it("uses the shared reference for the indicator of the selected group only", () => {
    const records = [
      ...Array.from({ length: 3 }, (_, i) => turn(`a${i}`, hourAgo(2) + i, { outputTokens: 2000 })),
      ...Array.from({ length: 3 }, (_, i) => turn(`o${i}`, hourAgo(2) + i, { model: "other", outputTokens: 100 })),
    ];
    const buckets = efficiencyBuckets(records, NOW, 1, reference, efficiencyKey(records[0]));
    expect(buckets.find((b) => b.value !== null)?.value).toBe(50);
  });
  it("charts tokens per request for all models and has no indicator without a reference", () => {
    const records = Array.from({ length: 4 }, (_, i) => turn(`a${i}`, hourAgo(2) + i, { outputTokens: 800, delegatedOutputTokens: 200 }));
    expect(efficiencyBuckets(records, NOW, 1, reference, null).find((b) => b.value !== null)?.value).toBe(1000);
    expect(efficiencyBuckets(records, NOW, 1, null, efficiencyKey(records[0])).every((b) => b.value === null)).toBe(true);
  });
  it("splits 7 days into 28 buckets", () => {
    expect(efficiencyBuckets([], NOW, 7, reference, null)).toHaveLength(28);
  });
});

describe("dashboard slice", () => {
  const records = [...many("lean", 500), ...many("typical", 1000), ...many("heavy", 2000)];
  it("scopes the reference to the whole history and selects the sample's group", () => {
    const d = efficiencyDashboard(records, NOW, 1, records.find((r) => r.model === "heavy"), false);
    expect(d.reference?.median).toBe(1000);
    expect(d.selected).toMatchObject({ model: "heavy", indicator: 50 });
    expect(d.unit).toBe("");
  });
  it("charts the reference itself for all models", () => {
    const d = efficiencyDashboard(records, NOW, 7, undefined, true);
    expect(d.unit).toBe("tokens/request");
    expect(d.selected).toBeNull();
    expect(d.buckets.filter((b) => b.value !== null).length).toBeGreaterThan(0);
  });
  it("is empty without eligible turns", () => {
    const d = efficiencyDashboard([turn("a", 1, { delegatedOutputTokens: null })], NOW, 1, undefined, false);
    expect(d.reference).toBeNull();
    expect(d.rows).toEqual([]);
    expect(d.buckets.every((b) => b.value === null)).toBe(true);
  });
  it("does not depend on the chart range for the indicator", () => {
    const day = efficiencyDashboard(records, NOW, 1, records[0], false);
    const week = efficiencyDashboard(records, NOW, 7, records[0], false);
    expect(day.rows).toEqual(week.rows);
    expect(DAY).toBe(86400000);
  });
});

describe("development preview data", () => {
  it("carries delegated tokens and scores at least two groups", () => {
    const records = previewRecords(NOW);
    expect(records.filter((m) => m.sourceKind === "subagent").every((m) => m.delegatedOutputTokens === null)).toBe(true);
    expect(records.some((m) => (m.delegatedOutputTokens ?? 0) > 0)).toBe(true);
    const rows = efficiencyRows(records, efficiencyReference(records));
    expect(rows.filter((r) => r.indicator !== null).length).toBeGreaterThanOrEqual(2);
  });
});
