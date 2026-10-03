import { describe, it, expect } from "vitest";
import {
  stats,
  summarize,
  change,
  select,
  cohort,
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
    "gpt-test",
    null,
    "1",
    "high",
  ]);
});
