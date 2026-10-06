import type { SourceId } from "./store/types";

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
  /** Bedrock inference-profile region (`us`, `eu`, ...); `unknown` without a prefix; null off Bedrock. */
  providerRegion?: string | null;
  /** Σ output tokens of the turn's qualifying API responses (200+ tokens each). */
  responseOutputTokens?: number | null;
  /** Σ seconds the model spent responding across those responses. */
  responseDurationSeconds?: number | null;
  responseCount?: number | null;
  /** Reasoning tokens inside `outputTokens`, when the tool reports them. */
  reasoningOutputTokens?: number | null;
  /**
   * Output tokens of delegated subagent work started during this primary turn and not already in
   * `outputTokens`. null: not final yet, or not applicable (subagent and legacy records).
   */
  delegatedOutputTokens?: number | null;
  /**
   * Where the coding tool ran, as a category; null when unknown. Not part of cohort identity and
   * not shown locally (shared with the community sample from 0.1.18).
   */
  surface?: "cli" | "desktop" | "ide" | "sdk" | "other" | null;
  /**
   * Input tokens of the turn including those served from the provider's prompt cache, those read
   * from the cache, and those written to it (Claude Code only). null when the source does not
   * report them. Not shown locally (shared with the community sample from 0.1.18).
   */
  inputTokens?: number | null;
  cacheReadInputTokens?: number | null;
  cacheWriteInputTokens?: number | null;
}
/** One qualifying API response from the live stream (local only, never persisted). */
export interface LiveResponse {
  id: string;
  completedAt: string;
  model: string | null;
  provider: string | null;
  client: string;
  sourceKind: string | null;
  metricVersion: string;
  reasoningEffort: string | null;
  outputTokens: number;
  durationSeconds: number;
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
    m.providerRegion ?? null,
    m.reasoningEffort ?? null,
    m.sourceKind ?? null,
  ]);
/** Output tokens per second while the model was responding; null without response timing. */
export const responseSpeed = (m: Metric): number | null => {
  const tokens = m.responseOutputTokens;
  const seconds = m.responseDurationSeconds;
  return typeof tokens === "number" &&
    typeof seconds === "number" &&
    tokens > 0 &&
    seconds > 0 &&
    Number.isFinite(tokens / seconds)
    ? tokens / seconds
    : null;
};
/** The one table of supported coding tools: display title and the two-letter picker chip. */
export const CODING_TOOLS: Record<SourceId, { title: string; chip: string }> = {
  codex: { title: "Codex", chip: "CX" },
  "claude-code": { title: "Claude Code", chip: "CC" },
  "grok-build": { title: "Grok Build", chip: "GB" },
  antigravity: { title: "Antigravity", chip: "AG" },
  opencode: { title: "OpenCode", chip: "OC" },
};
const codingTool = (id: string): (typeof CODING_TOOLS)[SourceId] | undefined =>
  CODING_TOOLS[id as SourceId];
/** Coding-tool name from its id ("claude-code" gives "Claude Code"). */
export const toolLabel = (id: string) => codingTool(id)?.title ?? "Coding tool";
/** Two-letter chip of a coding tool; the first two letters of an id missing from the table. */
export const toolChip = (id: string) => codingTool(id)?.chip ?? id.slice(0, 2).toUpperCase();
export const clientLabel = (m: Metric) => toolLabel(client(m));
/** Short note beside a Grok Build response speed: its value is a whole-turn average. */
export const GROK_RESPONSE_NOTE = "Grok Build: average over all model calls in a turn";
/** Full explanation of Grok Build's response speed for info popovers and help text. */
export const GROK_RESPONSE_EXPLANATION =
  "Grok Build records output tokens per turn, not per response, so its response speed is the turn's output tokens divided by the time its model calls spent generating (tool runs and permission waits excluded). Short calls are included, which can make it read lower than per-response measurements from Codex and Claude Code. Turns with nested agents are not counted.";
/** Efficiency indicator vocabulary (efficiency-v1). */
export const EFFICIENCY_NAME = "Efficiency indicator";
export const EFFICIENCY_SHORT = "Efficiency";
export const EFFICIENCY_DEFINITION =
  "Fewer output tokens per request scores higher. 100 = a typical request.";
export const EFFICIENCY_EXPLANATION =
  "The efficiency indicator compares the median output tokens a model spends to finish one of your requests (reasoning and delegated subagent work included) with the median across all your requests in the last 7 days. 100 is typical; 200 means half the tokens. It is an indicator, not a benchmark: it depends on what you ask each model to do, requests under 200 tokens are left out, and answer quality is not measured.";
export const EFFICIENCY_INSUFFICIENT =
  "Not enough requests yet: the efficiency indicator needs 20 eligible requests per model.";
export const isGrokBuild = (m: Metric | undefined) => !!m && client(m) === "grok-build";
/** Inference provider ids a Tokrate client can attribute from explicit evidence. */
export const PROVIDER_LABELS: Record<string, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  "amazon-bedrock": "Amazon Bedrock",
  "google-vertex": "Google Vertex AI",
  xai: "xAI",
  google: "Google",
};
/**
 * A raw provider id as OpenCode records it (a gateway, a vendor plan or a local server such as
 * `openrouter`, `kimi-for-coding` or `myomlx`): shown as it is, never mapped to a known provider.
 */
const RAW_PROVIDER = /^[a-z0-9][a-z0-9._-]{0,39}$/;
/**
 * Display name of a provider: a known provider by name, a raw id (from OpenCode) as it is;
 * missing, "unknown" and unusable ids are an unknown route.
 */
export const providerLabel = (provider: string | null | undefined) => {
  if (!provider || provider === "unknown") return "Unknown route";
  if (Object.hasOwn(PROVIDER_LABELS, provider)) return PROVIDER_LABELS[provider];
  return RAW_PROVIDER.test(provider) ? provider : "Unknown route";
};
/** "Amazon Bedrock route" / "openrouter route" / "Unknown route". */
export const providerRoute = (provider: string | null | undefined) => {
  const label = providerLabel(provider);
  return label === "Unknown route" ? label : `${label} route`;
};
const SUBAGENT_METRIC_VERSION = "claude-observed-subagent-turn-v1";
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
/** Vocabulary name of the measurement ("Turn speed"); precise definitions live in the explanation. */
export const measurementLabel = measurementTitle;
const TURN_EXPLANATIONS: Record<string, string> = {
  antigravity: "Prompt through final answer of one agent run, including tools & waiting.",
  opencode: "Prompt through final answer, including tools & waiting.",
};
/** Precise definition for the ⓘ explanation and group header tooltips. */
export const measurementExplanation = (m: Metric) =>
  ({
    turn:
      client(m) === "claude-code"
        ? "Human prompt through the terminal response in the primary transcript, including tools and waiting."
        : (TURN_EXPLANATIONS[client(m)] ??
          "Completed Codex turn: output tokens divided by the whole turn, including tools, reasoning and waiting."),
    subagent:
      "Subagent task prompt to final answer, including tools and waiting.",
    workTurn:
      "Matched Grok Build work turn, including nested agent output, tools and waiting.",
  })[measurementKind(m)];
/** Same coding tool, metric version and source kind: the only values that may share a scale. */
export const measurementGroupKey = (m: Metric) =>
  JSON.stringify([client(m), metricVersion(m), m.sourceKind ?? null]);
/** "Codex · Turn speed", "Claude Code · Subagent turn speed", ... */
export const measurementGroupTitle = (m: Metric) =>
  `${clientLabel(m)} · ${measurementTitle(m)}`;
const SCALE_STEPS = [20, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000];
/** The "nice" ceiling of 1.25 x the largest value, from the shared steps; minimum 20. */
export function niceScaleMax(largest: number | null | undefined): number {
  const target = 1.25 * (typeof largest === "number" && Number.isFinite(largest) ? Math.max(0, largest) : 0);
  const step = SCALE_STEPS.find((s) => s >= target - 1e-9);
  return step ?? Math.ceil(target / 250) * 250;
}
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
    response: stats(records.flatMap((m) => responseSpeed(m) ?? [])),
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
/** Exact-cohort records. Automatic and pinned-model selections use the newest record's cohort. */
export function select(records: Metric[], selection: string) {
  if (selection === "all") return [];
  const key = isCohortSelection(selection)
    ? selection
    : records[0] && cohort(records[0]);
  return records.filter((m) => cohort(m) === key);
}
/** A pinned exact cohort is a JSON array of its nine identity parts. */
export const isCohortSelection = (selection: string) => {
  if (!selection.startsWith("[")) return false;
  try {
    const parts: unknown = JSON.parse(selection);
    return Array.isArray(parts) && parts.length === 9;
  } catch {
    return false;
  }
};
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
/** The chart's time slots: 24 hourly slots for 24 h, 28 six-hour slots for 7 d. */
export function bucketRanges(now: number, days: number) {
  const count = days === 1 ? 24 : 28,
    step = (days * DAY) / count,
    start = now - days * DAY;
  return Array.from({ length: count }, (_, i) => ({
    at: start + i * step,
    end: start + (i + 1) * step,
  }));
}
export function buckets(
  records: Metric[],
  now: number,
  days: number,
  metric: "response" | "throughput" | "ttft",
) {
  return bucketRanges(now, days).map(({ at, end }) => {
    const s = summarize(period(records, at, end))[metric];
    return {
      at,
      end,
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
      if (providers.size > 1)
        parts.push(
          providerLabel(row.sample.provider) === "Unknown route"
            ? "provider unknown"
            : providerLabel(row.sample.provider),
        );
      if (!parts.length) parts.push(`parser ${parserVersion(row.sample)}`);
      row.qualifier = parts.join(" · ");
    }
  }
  return rows;
}
export interface CohortGroup {
  key: string;
  title: string;
  definition: string;
  rows: CohortRow[];
  /** Shared scale of the group's mini bars. */
  max: number;
  latestAt: number;
}
/** Rows grouped by measurement group, most recently active group first, sorted inside each group. */
export function groupCohortRows(rows: CohortRow[], sort: SortKey): CohortGroup[] {
  const groups = new Map<string, CohortRow[]>();
  for (const row of rows) {
    const key = measurementGroupKey(row.sample);
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return [...groups]
    .map(([key, list]) => ({
      key,
      title: measurementGroupTitle(list[0].sample),
      definition: measurementExplanation(list[0].sample),
      rows: sortCohortRows(list, sort),
      max: niceScaleMax(
        list.reduce((m, r) => Math.max(m, r.stats.throughput.median ?? 0), 0),
      ),
      latestAt: list.reduce((m, r) => Math.max(m, r.latestAt), 0),
    }))
    .sort((a, b) => b.latestAt - a.latestAt);
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
