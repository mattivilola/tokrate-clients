import { describe, it, expect } from "vitest";
import {
  stats,
  summarize,
  change,
  select,
  cohort,
  communityId,
  metricDefinition,
  alertsForCohorts,
  measurementExplanation,
  measurementLabel,
  signal,
  buckets,
  DAY,
  type Metric,
} from "./metrics";
const m = (p: Partial<Metric> = {}): Metric => ({
  id: "x",
  completedAt: "2026-10-04T12:00:00Z",
  model: "gpt-test",
  provider: "openai",
  clientVersion: "1",
  reasoningEffort: "high",
  outputTokens: 200,
  durationSeconds: 10,
  codexTTFTSeconds: 2,
  turnThroughputTPS: 20,
  ...p,
});
describe("metric parity", () => {
  it("has independent token/TTFT coverage and zero handling", () => {
    const s = summarize([
      m({ outputTokens: 5, codexTTFTSeconds: 0 }),
      m({ codexTTFTSeconds: null }),
    ]);
    expect(s.throughput.count).toBe(1);
    expect(s.ttft.median).toBe(0);
    expect(stats([]).median).toBeNull();
    expect(stats([1, 3, 7, 9]).median).toBe(5);
  });
  it("does not pool models or reasoning effort", () => {
    const a = m(),
      b = m({ reasoningEffort: "low" });
    expect(select([a, b], "all")).toEqual([]);
    expect(select([a, b], cohort(a))).toEqual([a]);
  });
  it("requires coverage and a positive previous median", () => {
    expect(change(stats([2]), stats([1]))).toBeNull();
    expect(change(stats([2, 2, 2, 2, 2]), stats([1, 1, 1, 1, 1]))).toBe(100);
    expect(change(stats([2, 2, 2, 2, 2]), stats([0, 0, 0, 0, 0]))).toBeNull();
  });
  it("keeps chart gaps and ignores future turns", () => {
    const now = Date.parse(m().completedAt);
    const b = buckets(
      [m({ completedAt: new Date(now + 100).toISOString() })],
      now,
      1,
      "throughput",
    );
    expect(b.every((x) => x.value === null)).toBe(true);
  });
  it("requires baseline across days and freshness", () => {
    const now = Date.parse(m().completedAt);
    const rows = [
      ...Array.from({ length: 5 }, (_, i) =>
        m({ id: `r${i}`, turnThroughputTPS: 10 }),
      ),
      ...Array.from({ length: 20 }, (_, i) =>
        m({
          id: `b${i}`,
          completedAt: new Date(now - (2 + (i % 2)) * DAY).toISOString(),
        }),
      ),
    ];
    expect(signal(rows, now, "throughput")).toMatch("Lower throughput");
    expect(signal(rows, now + 3600001, "throughput")).toMatch("stale");
    expect(signal(rows.slice(0, 5), now, "throughput")).toMatch(
      "More observations",
    );
  });
});
it("keeps missing and explicit unknown provider cohorts distinct", () => {
  expect(cohort(m({ provider: undefined }))).not.toBe(
    cohort(m({ provider: "unknown" })),
  );
  expect(JSON.parse(cohort(m({ provider: undefined })))).toEqual([
    "codex",
    "1",
    "codex-rollout-v1",
    "turn-v1",
    "gpt-test",
    null,
    "high",
    null,
  ]);
});
it("keeps each source/parser/metric cohort separate and uses the backend community key", () => {
  const codex = m();
  const claude = m({
    client: "claude-code",
    parserVersion: "claude-transcript-v1",
    metricVersion: "claude-observed-turn-v1",
    provider: "unknown",
    codexTTFTSeconds: null,
  });
  const grok = m({
    client: "grok-build",
    parserVersion: "grok-session-v1",
    metricVersion: "grok-observed-work-turn-v1",
    provider: "unknown",
    codexTTFTSeconds: null,
  });
  expect(new Set([cohort(codex), cohort(claude), cohort(grok)]).size).toBe(3);
  expect(JSON.parse(communityId(claude))).toEqual([
    "gpt-test",
    "unknown",
    "1",
    "claude-transcript-v1",
    "claude-observed-turn-v1",
    "high",
    "claude-code",
  ]);
  expect(measurementLabel(claude)).toBe("Transcript-observed turn throughput");
  expect(measurementLabel(grok)).toMatch("includes nested agent output");
  expect(summarize([claude]).ttft.count).toBe(0);
  expect(metricDefinition(claude)).not.toBe(metricDefinition(grok));
});
it("labels subagent turns and keeps their cohorts separate from primary Claude turns", () => {
  const claude = m({
    client: "claude-code",
    parserVersion: "claude-transcript-v2",
    metricVersion: "claude-observed-turn-v1",
    provider: "unknown",
    sourceKind: "primary",
    codexTTFTSeconds: null,
  });
  const subagent = m({
    ...claude,
    metricVersion: "claude-observed-subagent-turn-v1",
    sourceKind: "subagent",
  });
  expect(measurementLabel(subagent)).toBe("Subagent turn speed");
  expect(measurementExplanation(subagent)).toBe(
    "Subagent task prompt to final answer, including tools and waiting.",
  );
  expect(measurementLabel(claude)).toBe("Transcript-observed turn throughput");
  expect(measurementExplanation(claude)).toBeNull();
  expect(cohort(subagent)).not.toBe(cohort(claude));
  expect(metricDefinition(subagent)).not.toBe(metricDefinition(claude));
  expect(communityId(subagent)).not.toBe(communityId(claude));
  // Subagent cohorts stay selectable: selection never filters by source kind.
  expect(select([subagent, claude], cohort(subagent))).toEqual([subagent]);
  expect(select([subagent, claude], "latest")).toEqual([subagent]);
});
it("filters community alerts by matching published cohort IDs", () => {
  const rows = [
    { cohortId: "claude-cohort", message: "matching" },
    { cohortId: "grok-cohort", message: "other source" },
    { message: "no cohort in public alert contract" },
  ];
  expect(alertsForCohorts(rows, new Set(["claude-cohort"]))).toEqual([
    rows[0],
  ]);
});
