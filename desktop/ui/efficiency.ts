import { bucketRanges, client, period, stats, type Metric } from "./metrics";

/** Efficiency indicator (efficiency-v1): fewer output tokens per request scores higher. */

/** Turns under this many total tokens are trivial or automated and never count. */
export const EFFICIENCY_MIN_TOTAL_TOKENS = 200;
/** Eligible turns a group (and the reference) needs before an indicator is shown. */
export const EFFICIENCY_MIN_TURNS = 20;
/** Eligible turns a chart bucket needs; fewer leave a gap. */
export const EFFICIENCY_MIN_BUCKET_TURNS = 3;

const SUPPORTED_CLIENTS = [
  "codex",
  "claude-code",
  "grok-build",
  "antigravity",
  "opencode",
  "kimi-code",
];
const isCount = (v: unknown): v is number =>
  typeof v === "number" && Number.isFinite(v) && v >= 0;

/** The group's effort part: a missing or empty effort is "unknown". */
export const effortOf = (m: Metric) => (m.reasoningEffort ? m.reasoningEffort : "unknown");
/** Group identity: model plus reasoning effort, combined across tools, providers and versions. */
export const efficiencyKey = (m: Metric) => JSON.stringify([m.model ?? null, effortOf(m)]);

/** Output plus delegated output tokens; null while delegated work is not final or not applicable. */
export function totalTokens(m: Metric): number | null {
  return isCount(m.outputTokens) && isCount(m.delegatedOutputTokens)
    ? m.outputTokens + m.delegatedOutputTokens
    : null;
}

/** The turn's total tokens when it is eligible for the indicator, else null. */
export function eligibleTotal(m: Metric): number | null {
  if (
    m.sourceKind !== "primary" ||
    !m.model ||
    !SUPPORTED_CLIENTS.includes(client(m))
  )
    return null;
  const total = totalTokens(m);
  return total !== null && total >= EFFICIENCY_MIN_TOTAL_TOKENS ? total : null;
}

/** Linear-interpolation percentile of an ascending list (p = 0.5 is the usual median). */
export function percentile(sorted: number[], p: number): number | null {
  if (!sorted.length) return null;
  const at = (sorted.length - 1) * p;
  const lo = Math.floor(at);
  const hi = Math.ceil(at);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (at - lo);
}

const ascending = (values: number[]) => [...values].sort((a, b) => a - b);

export interface EfficiencyReference {
  /** Median total tokens over all eligible turns. */
  median: number;
  turns: number;
}

/** R: the median over every eligible turn of the window; null below the 20-turn floor. */
export function efficiencyReference(records: Metric[]): EfficiencyReference | null {
  const totals = records.flatMap((m) => eligibleTotal(m) ?? []);
  const median = stats(totals).median;
  return totals.length >= EFFICIENCY_MIN_TURNS && median !== null && median > 0
    ? { median, turns: totals.length }
    : null;
}

/** 100 = typical; 200 = half the tokens; 50 = twice the tokens. */
export const indicatorOf = (reference: number, median: number) =>
  Math.round((100 * reference) / median);

export interface EfficiencyRow {
  key: string;
  model: string;
  /** Reasoning effort, "unknown" when none was reported. */
  effort: string;
  /** The provider when every turn of the group names the same one, else null. */
  provider: string | null;
  /** Eligible turns. */
  turns: number;
  /** null below 20 eligible turns or without a reference. */
  indicator: number | null;
  medianTokens: number;
  p25Tokens: number;
  p75Tokens: number;
  /** Median of reasoning/output over turns that report reasoning tokens; null without any. */
  reasoningShare: number | null;
  /** Σ delegated / Σ total. */
  delegatedShare: number;
  latestAt: number;
}

/** One row per model and effort over the given eligible-turn window. */
export function efficiencyRows(
  records: Metric[],
  reference: EfficiencyReference | null,
): EfficiencyRow[] {
  const groups = new Map<string, Metric[]>();
  for (const m of records) {
    if (eligibleTotal(m) === null) continue;
    const key = efficiencyKey(m);
    const list = groups.get(key);
    if (list) list.push(m);
    else groups.set(key, [m]);
  }
  return [...groups].map(([key, list]) => {
    const totals = ascending(list.map((m) => eligibleTotal(m) ?? 0));
    const median = percentile(totals, 0.5) ?? 0;
    const shares = list.flatMap((m) =>
      isCount(m.reasoningOutputTokens) && m.outputTokens > 0
        ? [m.reasoningOutputTokens / m.outputTokens]
        : [],
    );
    const sumTotal = totals.reduce((sum, v) => sum + v, 0);
    const sumDelegated = list.reduce((sum, m) => sum + (m.delegatedOutputTokens ?? 0), 0);
    const providers = new Set(list.map((m) => m.provider ?? "unknown"));
    return {
      key,
      model: list[0].model ?? "",
      effort: effortOf(list[0]),
      provider: providers.size === 1 ? [...providers][0] : null,
      turns: list.length,
      indicator:
        reference && list.length >= EFFICIENCY_MIN_TURNS ? indicatorOf(reference.median, median) : null,
      medianTokens: median,
      p25Tokens: percentile(totals, 0.25) ?? 0,
      p75Tokens: percentile(totals, 0.75) ?? 0,
      reasoningShare: shares.length ? stats(shares).median : null,
      delegatedShare: sumTotal > 0 ? sumDelegated / sumTotal : 0,
      latestAt: list.reduce((max, m) => Math.max(max, Date.parse(m.completedAt)), 0),
    };
  });
}

export type EfficiencySort = "efficiency" | "recent";

/** Highest indicator first; rows without one follow, the most-evidenced first. */
export function sortEfficiencyRows(rows: EfficiencyRow[], sort: EfficiencySort): EfficiencyRow[] {
  return [...rows].sort((a, b) =>
    sort === "recent"
      ? b.latestAt - a.latestAt
      : (b.indicator ?? -1) - (a.indicator ?? -1) ||
        b.turns - a.turns ||
        b.latestAt - a.latestAt,
  );
}

/** Bar scale: the largest indicator, never below the 100 "typical" tick. */
export const efficiencyScaleMax = (rows: EfficiencyRow[]) =>
  rows.reduce((max, row) => Math.max(max, row.indicator ?? 0), 100);

export interface EfficiencyBucket {
  at: number;
  end: number;
  value: number | null;
  min: number | null;
  max: number | null;
  count: number;
}

/**
 * Chart buckets of the selected range. With a group: the bucket's indicator against the shared
 * reference (a gap without one). Without a group: the reference itself, median total tokens per
 * request. Either way a bucket needs 3 eligible turns.
 */
export function efficiencyBuckets(
  records: Metric[],
  now: number,
  days: number,
  reference: EfficiencyReference | null,
  groupKey: string | null,
): EfficiencyBucket[] {
  const eligible = records.filter(
    (m) => eligibleTotal(m) !== null && (groupKey === null || efficiencyKey(m) === groupKey),
  );
  return bucketRanges(now, days).map(({ at, end }) => {
    const totals = period(eligible, at, end).flatMap((m) => eligibleTotal(m) ?? []);
    const median = stats(totals).median;
    const value =
      totals.length < EFFICIENCY_MIN_BUCKET_TURNS || median === null
        ? null
        : groupKey === null
          ? median
          : reference
            ? indicatorOf(reference.median, median)
            : null;
    return { at, end, value, min: value, max: value, count: value === null ? 0 : totals.length };
  });
}

/** Everything the efficiency surfaces need from one window of records and the current selection. */
export function efficiencyDashboard(
  records: Metric[],
  now: number,
  days: number,
  sample: Metric | undefined,
  isAll: boolean,
) {
  const reference = efficiencyReference(records);
  const rows = efficiencyRows(records, reference);
  const selected = sample ? (rows.find((row) => row.key === efficiencyKey(sample)) ?? null) : null;
  const groupKey = isAll ? null : sample ? efficiencyKey(sample) : null;
  return {
    reference,
    rows,
    selected,
    /** The chart plots tokens per request for all models, the indicator for one model. */
    unit: isAll ? "tokens/request" : "",
    buckets: efficiencyBuckets(isAll || groupKey ? records : [], now, days, reference, groupKey),
  };
}
export type EfficiencyDashboard = ReturnType<typeof efficiencyDashboard>;
