export interface Metric {
  id: string;
  completedAt: string;
  model: string | null;
  provider?: string | null;
  clientVersion?: string | null;
  reasoningEffort?: string | null;
  client?: string;
  parserVersion?: string;
  metricVersion?: string;
  sourceKind?: string | null;
  outputTokens: number;
  durationSeconds: number;
  codexTTFTSeconds: number | null;
  turnThroughputTPS: number;
}
export interface Stats {
  median: number | null;
  min: number | null;
  max: number | null;
  count: number;
}
export const DAY = 86400000;
export const client = (m: Metric) => m.client ?? "codex";
export const parserVersion = (m: Metric) =>
  m.parserVersion ?? "codex-rollout-v1";
export const metricVersion = (m: Metric) => m.metricVersion ?? "turn-v1";
export const metricDefinition = (m: Metric) =>
  JSON.stringify([client(m), parserVersion(m), metricVersion(m)]);
export const cohort = (m: Metric) =>
  JSON.stringify([
    client(m),
    m.clientVersion ?? null,
    parserVersion(m),
    metricVersion(m),
    m.model ?? null,
    m.provider ?? null,
    m.reasoningEffort ?? null,
    m.sourceKind ?? null,
  ]);
export const clientLabel = (m: Metric) =>
  ({ codex: "Codex", "claude-code": "Claude Code", "grok-build": "Grok Build" })[
    client(m)
  ] ?? "Coding tool";
const SUBAGENT_METRIC_VERSION = "claude-observed-subagent-turn-v1";
export const measurementLabel = (m: Metric) =>
  metricVersion(m) === SUBAGENT_METRIC_VERSION
    ? "Subagent turn speed"
    : client(m) === "claude-code"
      ? "Transcript-observed turn throughput"
      : client(m) === "grok-build"
        ? "Work-turn throughput · includes nested agent output"
        : "Completed-turn throughput";
export type MeasurementKind = "turn" | "subagent" | "workTurn";
export const isSubagent = (m: Metric) =>
  metricVersion(m) === SUBAGENT_METRIC_VERSION || m.sourceKind === "subagent";
export const measurementKind = (m: Metric): MeasurementKind =>
  metricVersion(m) === SUBAGENT_METRIC_VERSION
    ? "subagent"
    : client(m) === "grok-build"
      ? "workTurn"
      : "turn";
/** Short chip shown next to a model; null for the default whole-turn measurement. */
export const measurementChip = (m: Metric) =>
  ({ turn: null, subagent: "Subagent", workTurn: "Work turn" })[
    measurementKind(m)
  ];
/** Vocabulary name of the number ("Turn speed", never streaming speed). */
export const measurementTitle = (m: Metric) =>
  ({
    turn: "Turn speed",
    subagent: "Subagent turn speed",
    workTurn: "Work-turn speed",
  })[measurementKind(m)];
/** One-line definition shown next to a turn-speed readout. */
export const measurementDefinition = (m: Metric | undefined) =>
  ({
    turn: "Whole turn, including tools and waiting.",
    subagent:
      "Subagent task prompt to final answer, including tools and waiting.",
    workTurn:
      "Whole work turn, including nested subagent output, tools and waiting.",
  })[m ? measurementKind(m) : "turn"];
export const measurementExplanation = (m: Metric) =>
  metricVersion(m) === SUBAGENT_METRIC_VERSION
    ? "Subagent task prompt to final answer, including tools and waiting."
    : null;
export const label = (m: Metric) =>
  `${m.model ?? "Unknown model"} · ${m.reasoningEffort ?? "unknown"} effort · ${clientLabel(m)} ${m.clientVersion ?? "version unknown"}`;
export const communityId = (m: Metric) =>
  JSON.stringify([
    m.model ?? "unknown",
    m.provider ?? "unknown",
    m.clientVersion ?? "unknown",
    parserVersion(m),
    metricVersion(m),
    m.reasoningEffort ?? "unknown",
    client(m),
  ]);
export function alertsForCohorts<T extends { cohortId?: unknown }>(
  alerts: T[],
  cohortIds: Set<string>,
): T[] {
  return alerts.filter(
    (alert) =>
      typeof alert.cohortId === "string" && cohortIds.has(alert.cohortId),
  );
}
export function stats(values: number[]): Stats {
  const s = values
    .filter(Number.isFinite)
    .filter((n) => n >= 0)
    .sort((a, b) => a - b);
  const n = s.length;
  return {
    median: n ? (n % 2 ? s[n >> 1] : s[n / 2 - 1] / 2 + s[n / 2] / 2) : null,
    min: s[0] ?? null,
    max: s[n - 1] ?? null,
    count: n,
  };
}
export function summarize(records: Metric[]) {
  return {
    throughput: stats(
      records
        .filter((m) => m.outputTokens >= 20)
        .map((m) => m.turnThroughputTPS),
    ),
    ttft: stats(
      records.flatMap((m) =>
        m.codexTTFTSeconds === null ? [] : [m.codexTTFTSeconds],
      ),
    ),
  };
}
export function period(records: Metric[], start: number, end: number) {
  return records.filter(
    (m) =>
      Date.parse(m.completedAt) >= start && Date.parse(m.completedAt) < end,
  );
}
export function change(current: Stats, previous: Stats) {
  return current.count >= 5 &&
    previous.count >= 5 &&
    previous.median !== null &&
    previous.median > 0 &&
    current.median !== null
    ? (current.median / previous.median - 1) * 100
    : null;
}
export function select(records: Metric[], selection: string) {
  if (selection === "all") return [];
  const key =
    selection === "latest" ? records[0] && cohort(records[0]) : selection;
  return records.filter((m) => cohort(m) === key);
}
export function signal(
  records: Metric[],
  now: number,
  metric: "throughput" | "ttft",
): string {
  const eligible = records.filter((m) =>
    metric === "throughput"
      ? m.outputTokens >= 20
      : m.codexTTFTSeconds !== null,
  );
  const current = period(eligible, now - DAY, now + 1),
    baseline = period(eligible, now - 7 * DAY, now - DAY);
  const days = new Set(baseline.map((m) => m.completedAt.slice(0, 10))).size;
  if (current.length < 5 || baseline.length < 20 || days < 2)
    return "More observations needed for a personal baseline";
  if (!current.some((m) => Date.parse(m.completedAt) >= now - 3600000))
    return "Recent observations are stale";
  const a = summarize(current)[metric].median,
    b = summarize(baseline)[metric].median;
  if (a === null || b === null || b <= 0) return "Baseline unavailable";
  const changed =
    metric === "throughput" ? a <= b * 0.7 : a >= b * 1.5 && a - b >= 1;
  return changed
    ? metric === "throughput"
      ? "Lower throughput than your baseline"
      : "Longer first-token waits than your baseline"
    : "No threshold crossing in your observations";
}
export function buckets(
  records: Metric[],
  now: number,
  days: number,
  metric: "throughput" | "ttft",
) {
  const count = days === 1 ? 24 : 28,
    step = (days * DAY) / count,
    start = now - days * DAY;
  return Array.from({ length: count }, (_, i) => {
    const s = summarize(
      period(records, start + i * step, start + (i + 1) * step),
    )[metric];
    return {
      at: start + i * step,
      end: start + (i + 1) * step,
      value: s.median,
      min: s.min,
      max: s.max,
      count: s.count,
    };
  });
}
/** Fewer turns than this make a 24 h median too noisy to compare against. */
export const MIN_DELTA_TURNS = 3;
/** Percent difference of the latest turn against the cohort's own median; null without enough evidence. */
export function deltaVsMedian(
  latest: number | null | undefined,
  median: Stats,
): { percent: number; median: number; turns: number } | null {
  if (
    typeof latest !== "number" ||
    !Number.isFinite(latest) ||
    latest < 0 ||
    median.count < MIN_DELTA_TURNS ||
    median.median === null ||
    median.median <= 0
  )
    return null;
  return {
    percent: ((latest - median.median) / median.median) * 100,
    median: median.median,
    turns: median.count,
  };
}
/** "just now", "5 min ago", "3 h ago", "yesterday", "4 d ago" (same rules as the Mac app). */
export function relativeTime(at: number, now: number): string {
  const seconds = (now - at) / 1000;
  if (!Number.isFinite(seconds)) return "Unavailable";
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${Math.max(1, minutes)} min ago`;
  const hours = Math.floor(seconds / 3600);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.floor(seconds / 86400);
  return days === 1 ? "yesterday" : `${days} d ago`;
}
export interface CohortRow {
  key: string;
  sample: Metric;
  latestAt: number;
  stats: ReturnType<typeof summarize>;
  /** Added only when two entries would otherwise look identical. */
  qualifier: string | null;
}
/** Groups records into exact cohorts, newest activity first, with disambiguating qualifiers. */
export function cohortRows(
  records: Metric[],
  start: number,
  end: number,
): CohortRow[] {
  const groups = new Map<string, Metric[]>();
  for (const m of records) {
    const key = cohort(m);
    const list = groups.get(key);
    if (list) list.push(m);
    else groups.set(key, [m]);
  }
  const rows = [...groups].map(([key, list]) => ({
    key,
    sample: list[0],
    latestAt: list.reduce(
      (latest, m) => Math.max(latest, Date.parse(m.completedAt)),
      0,
    ),
    stats: summarize(period(list, start, end)),
    qualifier: null as string | null,
  }));
  rows.sort((a, b) => b.latestAt - a.latestAt);
  const base = (m: Metric) =>
    [client(m), m.model ?? "", m.reasoningEffort ?? "", measurementKind(m)].join(
      "\u001f",
    );
  const siblings = new Map<string, CohortRow[]>();
  for (const row of rows) {
    const k = base(row.sample);
    siblings.set(k, [...(siblings.get(k) ?? []), row]);
  }
  for (const group of siblings.values()) {
    if (group.length < 2) continue;
    const versions = new Set(group.map((r) => r.sample.clientVersion ?? ""));
    const providers = new Set(group.map((r) => r.sample.provider ?? ""));
    for (const row of group) {
      const parts: string[] = [];
      if (versions.size > 1)
        parts.push(
          row.sample.clientVersion ? `v${row.sample.clientVersion}` : "version unknown",
        );
      if (providers.size > 1) parts.push(row.sample.provider ?? "provider unknown");
      if (!parts.length) parts.push(`parser ${parserVersion(row.sample)}`);
      row.qualifier = parts.join(" · ");
    }
  }
  return rows;
}
export type SortKey = "recent" | "throughput" | "ttft";
/** Never ranks different measurement definitions against each other. */
export function sortCohortRows(rows: CohortRow[], sort: SortKey): CohortRow[] {
  if (sort === "recent") return rows;
  return [...rows].sort((a, b) => {
    const definition = metricDefinition(a.sample).localeCompare(
      metricDefinition(b.sample),
    );
    if (definition) return definition;
    return sort === "throughput"
      ? (b.stats.throughput.median ?? -1) - (a.stats.throughput.median ?? -1)
      : (a.stats.ttft.median ?? Infinity) - (b.stats.ttft.median ?? Infinity);
  });
}
