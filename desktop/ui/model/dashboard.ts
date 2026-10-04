import {
  DAY,
  buckets,
  change,
  client,
  cohort,
  cohortRows,
  communityId,
  deltaVsMedian,
  groupCohortRows,
  measurementGroupKey,
  niceScaleMax,
  period,
  relativeTime,
  select,
  signal,
  summarize,
  type CohortRow,
  type Metric,
  type SortKey,
} from "../metrics";
import type { Board, CommunityCohort, ProviderFilter, ToolFilter } from "../store/types";

export interface DashboardInput {
  records: Metric[];
  selection: string;
  days: number;
  tool: ToolFilter;
  provider: ProviderFilter;
  now: number;
  sort: SortKey;
}

export const CLIENT_ORDER = ["codex", "claude-code", "grok-build"] as const;

/** Everything the home flyout and the history window render, derived purely from the records. */
export function buildDashboard(input: DashboardInput) {
  const { records, days, tool, provider, now, sort } = input;
  const retained = records.filter((m) => {
    const at = Date.parse(m.completedAt);
    return at >= now - 7 * DAY && at <= now;
  });
  const filtered = retained.filter(
    (m) =>
      (tool === "all" || client(m) === tool) &&
      (provider === "all" || (m.provider ?? "unknown") === provider),
  );
  const rangeStart = now - days * DAY;
  const cohorts = cohortRows(filtered, rangeStart, now + 1);
  const isAll = input.selection === "all";
  // A saved selection whose cohort left the 7-day window behaves like "latest".
  const selection =
    isAll || input.selection === "latest"
      ? input.selection
      : select(filtered, input.selection).length
        ? input.selection
        : "latest";
  const selected = select(filtered, selection);
  const sample = selected[0];
  const selectedKey = sample ? cohort(sample) : null;
  const inRange = period(selected, rangeStart, now + 1);
  const latest = selected.find((m) => m.outputTokens >= 20);
  const last24h = summarize(period(selected, now - DAY, now + 1));
  const previous24h = summarize(period(selected, now - 2 * DAY, now - DAY));
  const delta = deltaVsMedian(latest?.turnThroughputTPS, last24h.throughput);
  // Hero scale: the latest value or the group's largest 24 h median, never other measurement groups.
  const latestGroup = latest ? measurementGroupKey(latest) : null;
  const groupMedian24h = latestGroup
    ? cohortRows(
        filtered.filter((m) => measurementGroupKey(m) === latestGroup),
        now - DAY,
        now + 1,
      ).reduce((max, row) => Math.max(max, row.stats.throughput.median ?? 0), 0)
    : 0;
  const tools = CLIENT_ORDER.filter((id) =>
    retained.some((m) => client(m) === id),
  );
  return {
    now,
    days,
    filtered,
    cohorts,
    groups: groupCohortRows(cohorts, "recent"),
    compareGroups: groupCohortRows(cohorts, sort),
    gaugeMax: niceScaleMax(Math.max(latest?.turnThroughputTPS ?? 0, groupMedian24h)),
    isAll,
    selection,
    selected,
    selectedKey,
    sample,
    inRange,
    latest,
    latestRelative: latest
      ? relativeTime(Date.parse(latest.completedAt), now)
      : null,
    delta,
    summary: summarize(inRange),
    last24h,
    recent15m: summarize(period(selected, now - 900000, now + 1)),
    change: {
      throughput: change(last24h.throughput, previous24h.throughput),
      ttft: change(last24h.ttft, previous24h.ttft),
    },
    signals: {
      throughput: signal(selected, now, "throughput"),
      ttft: signal(selected, now, "ttft"),
    },
    /** Rows of the full-history table: every filtered cohort when comparing, else the selection. */
    historyRows: period(isAll ? filtered : selected, rangeStart, now + 1),
    allInRange: period(filtered, rangeStart, now + 1),
    tools,
    hasRecords: retained.length > 0,
  };
}
export type Dashboard = ReturnType<typeof buildDashboard>;

export interface CommunityLine {
  median: number;
  windowLabel: string;
  /** Signed percent of your median against the community median, when comparable. */
  position: number | null;
  caution: "Early data" | "Older data" | null;
  cohort: CommunityCohort;
}

const windowLabels: Record<string, string> = {
  "15m": "15 min",
  "24h": "24 h",
  "24hr": "24 h",
  "7d": "7 d",
  "30d": "30 d",
};
export const communityWindowLabel = (window: string | undefined) =>
  windowLabels[window ?? "24h"] ?? window ?? "24 h";

export function communityLine(
  board: Board | null,
  dashboard: Dashboard,
): CommunityLine | null {
  if (!board || !dashboard.sample) return null;
  const wanted = communityId(dashboard.sample);
  const match = (board.cohorts ?? []).find((c) => c.id === wanted);
  const median = match?.medianThroughput;
  if (!match || typeof median !== "number" || !(median > 0)) return null;
  const window = board.window ?? "24h";
  const mine =
    window === "15m"
      ? dashboard.recent15m.throughput
      : window === "24h" || window === "24hr"
        ? dashboard.last24h.throughput
        : null;
  const position =
    mine && mine.count >= 3 && mine.median !== null
      ? Math.round(((mine.median - median) / median) * 100)
      : null;
  const caution =
    board.state === "stale"
      ? "Older data"
      : board.state === "insufficient_data" ||
          board.methodology?.publicationMode === "early_data"
        ? "Early data"
        : null;
  return {
    median,
    windowLabel: communityWindowLabel(window),
    position,
    caution,
    cohort: match,
  };
}

/** Published cohorts for the current scope (all filtered cohorts, or the selected exact cohort). */
export function communityRows(
  board: Board | null,
  dashboard: Dashboard,
  tool: ToolFilter,
  provider: ProviderFilter,
): CommunityCohort[] {
  if (!board) return [];
  const wanted = dashboard.sample ? communityId(dashboard.sample) : null;
  return (Array.isArray(board.cohorts) ? board.cohorts : []).filter(
    (c) =>
      (dashboard.isAll || c.id === wanted) &&
      (tool === "all" || c.client === tool) &&
      (provider === "all" || c.provider === provider),
  );
}

export type { CohortRow };
