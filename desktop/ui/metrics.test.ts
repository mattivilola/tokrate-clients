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
it("describes measurement kinds with the shared vocabulary", async () => {
  const { measurementChip, measurementTitle, measurementDefinition, isSubagent } =
    await import("./metrics");
  const base = m({ client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", codexTTFTSeconds: null });
  const subagent = m({ ...base, metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent" });
  const grok = m({ client: "grok-build", parserVersion: "grok-session-v1", metricVersion: "grok-observed-work-turn-v1" });
  expect(measurementChip(m())).toBeNull();
  expect(measurementChip(subagent)).toBe("Subagent");
  expect(measurementChip(grok)).toBe("Work turn");
  expect(measurementTitle(m())).toBe("Turn speed");
  expect(measurementTitle(subagent)).toBe("Subagent turn speed");
  expect(isSubagent(subagent)).toBe(true);
  expect(isSubagent(base)).toBe(false);
  expect(measurementDefinition(m())).toBe("Whole turn, including tools and waiting.");
  expect(measurementDefinition(subagent)).toMatch("task prompt to final answer");
  expect(measurementDefinition(undefined)).toBe("Whole turn, including tools and waiting.");
});
it("compares the latest turn with the cohort's own median only with enough turns", async () => {
  const { deltaVsMedian } = await import("./metrics");
  expect(deltaVsMedian(60, stats([50, 50]))).toBeNull();
  expect(deltaVsMedian(null, stats([50, 50, 50]))).toBeNull();
  expect(deltaVsMedian(60, stats([0, 0, 0]))).toBeNull();
  const delta = deltaVsMedian(60, stats([50, 50, 50]));
  expect(delta?.percent).toBeCloseTo(20);
  expect(delta?.turns).toBe(3);
});
it("formats relative times like the Mac app", async () => {
  const { relativeTime } = await import("./metrics");
  const now = Date.parse("2026-10-04T12:00:00Z");
  const ago = (seconds: number) => relativeTime(now - seconds * 1000, now);
  expect(ago(10)).toBe("just now");
  expect(ago(90)).toBe("2 min ago");
  expect(ago(50 * 60)).toBe("50 min ago");
  expect(ago(3 * 3600 + 120)).toBe("3 h ago");
  expect(ago(30 * 3600)).toBe("yesterday");
  expect(ago(4 * 86400 + 60)).toBe("4 d ago");
});
it("builds exact cohorts with qualifiers only where entries look identical", async () => {
  const { cohortRows, sortCohortRows } = await import("./metrics");
  const now = Date.parse(m().completedAt);
  const a = m({ id: "a", clientVersion: "1", turnThroughputTPS: 20 });
  const b = m({ id: "b", clientVersion: "2", completedAt: new Date(now - 1000).toISOString(), turnThroughputTPS: 80 });
  const other = m({ id: "c", model: "other-model", completedAt: new Date(now - 2000).toISOString(), turnThroughputTPS: 50 });
  const rows = cohortRows([a, b, other], now - DAY, now + 1);
  expect(rows.map((r) => r.sample.id)).toEqual(["a", "b", "c"]);
  expect(rows.find((r) => r.sample.id === "a")?.qualifier).toBe("v1");
  expect(rows.find((r) => r.sample.id === "b")?.qualifier).toBe("v2");
  expect(rows.find((r) => r.sample.id === "c")?.qualifier).toBeNull();
  expect(sortCohortRows(rows, "throughput").map((r) => r.sample.id)).toEqual(["b", "c", "a"]);
});
it("never ranks different measurement definitions together", async () => {
  const { cohortRows, sortCohortRows } = await import("./metrics");
  const now = Date.parse(m().completedAt);
  const fast = m({ id: "sub", client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent", turnThroughputTPS: 200, codexTTFTSeconds: null });
  const slow = m({ id: "turn", client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", turnThroughputTPS: 10, codexTTFTSeconds: null });
  const rows = sortCohortRows(cohortRows([fast, slow], now - DAY, now + 1), "throughput");
  // Grouped by definition first, so the 200 tok/s subagent turn is not ranked above the primary turn.
  expect(rows.map((r) => r.sample.metricVersion)).toEqual([
    "claude-observed-subagent-turn-v1",
    "claude-observed-turn-v1",
  ]);
});
it("keeps chart bucket min, max and counts", () => {
  const now = Date.parse(m().completedAt);
  const rows = [
    m({ id: "1", completedAt: new Date(now - 60000).toISOString(), turnThroughputTPS: 10 }),
    m({ id: "2", completedAt: new Date(now - 120000).toISOString(), turnThroughputTPS: 30 }),
  ];
  const last = buckets(rows, now, 1, "throughput").at(-1)!;
  expect(last).toMatchObject({ value: 20, min: 10, max: 30, count: 2 });
});
