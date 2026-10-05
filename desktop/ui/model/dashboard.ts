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
  responseSpeed,
  select,
  signal,
  summarize,
  type CohortRow,
  type LiveResponse,
  type Metric,
  type SortKey,
} from "../metrics";
import { efficiencyDashboard } from "../efficiency";
import {
  autoSelection,
  fallbackModel,
  liveValue,
  modelSelection,
  modelSpeedRows,
  parseSelection,
  sameModel,
  type ModelKey,
} from "../response";
import type { Board, CommunityCohort, ProviderFilter, ToolFilter } from "../store/types";

export interface DashboardInput {
  records: Metric[];
  selection: string;
  days: number;
  tool: ToolFilter;
  provider: ProviderFilter;
  now: number;
  sort: SortKey;
  /** Live responses completed since launch (local only). */
  live?: LiveResponse[];
  /** The model the native selector follows while live responses exist. */
  active?: ModelKey | null;
}

export const CLIENT_ORDER = ["codex", "claude-code", "grok-build"] as const;

/** Everything the home flyout and the history window render, derived purely from the records. */
export function buildDashboard(input: DashboardInput) {
  const { records, days, tool, provider, now, sort } = input;
  const live = input.live ?? [];
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
  let mode = parseSelection(input.selection);
  // A saved cohort that left the 7-day window behaves like Auto.
  if (mode.kind === "cohort" && !select(filtered, mode.key).length)
    mode = { kind: "auto", tool: null };
  const isAll = mode.kind === "all";
  const selection =
    mode.kind === "auto"
      ? autoSelection(mode.tool)
      : mode.kind === "all"
        ? "all"
        : mode.kind === "model"
          ? modelSelection(mode.key)
          : mode.key;

  // The model the dashboard follows. Auto uses the live active model, else the newest turn.
  const autoPool =
    mode.kind === "auto" && mode.tool
      ? filtered.filter((m) => client(m) === mode.tool)
      : filtered;
  const activeKey: ModelKey | null =
    mode.kind === "auto"
      ? (input.active ?? fallbackModel(autoPool))
      : mode.kind === "model"
        ? mode.key
        : mode.kind === "cohort"
          ? { model: mode.model, provider: mode.provider }
          : null;
  const liveDriven = mode.kind === "auto" && !!input.active;
  const scopeRecords =
    mode.kind === "cohort"
      ? select(filtered, mode.key)
      : activeKey
        ? autoPool.filter((m) => sameModel(m, activeKey))
        : [];
  // Turn-level views stay on one exact cohort: pinned, or the cohort of the newest scoped turn.
  const selected = isAll ? [] : select(scopeRecords, mode.kind === "cohort" ? mode.key : "auto");
  const sample = selected[0];
  const selectedKey = sample ? cohort(sample) : null;
  const scopeClient =
    mode.kind === "cohort" ? mode.client : mode.kind === "auto" ? mode.tool : null;

  const inRange = period(selected, rangeStart, now + 1);
  const responseInRange = period(scopeRecords, rangeStart, now + 1);
  const latest = selected.find((m) => m.outputTokens >= 20);
  const last24h = summarize(period(selected, now - DAY, now + 1));
  const previous24h = summarize(period(selected, now - 2 * DAY, now - DAY));
  const response24 = summarize(period(scopeRecords, now - DAY, now + 1));
  const previousResponse24 = summarize(
    period(scopeRecords, now - 2 * DAY, now - DAY),
  );

  // Hero: the live median of the last five responses, else the scope's newest turn with response data.
  const liveReading =
    activeKey && !isAll
      ? liveValue(live, { ...activeKey, client: scopeClient }, now)
      : null;
  const latestResponseTurn = scopeRecords.find((m) => responseSpeed(m) !== null);
  const hero: {
    value: number | null;
    source: "live" | "turn" | null;
    at: number | null;
    count: number;
  } = liveReading
    ? { value: liveReading.speed, source: "live", at: liveReading.lastAt, count: liveReading.count }
    : latestResponseTurn
      ? {
          value: responseSpeed(latestResponseTurn),
          source: "turn",
          at: Date.parse(latestResponseTurn.completedAt),
          count: latestResponseTurn.responseCount ?? 0,
        }
      : { value: null, source: null, at: null, count: 0 };
  const responseDelta = deltaVsMedian(hero.value, response24.response);
  const delta = deltaVsMedian(latest?.turnThroughputTPS, last24h.throughput);

  // Response speed is one definition, so every model's 24 h median shares one gauge scale.
  const modelRows = modelSpeedRows(filtered, now - DAY, now + 1);
  const gaugeMax = niceScaleMax(
    Math.max(hero.value ?? 0, ...modelRows.map((row) => row.median ?? 0)),
  );
  const turnLatestGroup = latest ? measurementGroupKey(latest) : null;
  const groupMedian24h = turnLatestGroup
    ? cohortRows(
        filtered.filter((m) => measurementGroupKey(m) === turnLatestGroup),
        now - DAY,
        now + 1,
      ).reduce((max, row) => Math.max(max, row.stats.throughput.median ?? 0), 0)
    : 0;
  const tools = CLIENT_ORDER.filter((id) =>
    retained.some((m) => client(m) === id),
  );
  // The model's own tools in the last 24 h, for the hero chips.
  const scopeTools = CLIENT_ORDER.filter((id) =>
    scopeRecords.some((m) => client(m) === id),
  );
  const liveLatest = liveReading
    ? live.find((r) => Date.parse(r.completedAt) === liveReading.lastAt)
    : undefined;
  return {
    now,
    days,
    filtered,
    cohorts,
    groups: groupCohortRows(cohorts, "recent"),
    compareGroups: groupCohortRows(cohorts, sort),
    modelRows,
    /** Efficiency indicator over the whole 7-day history, independent of the chart range. */
    efficiency: efficiencyDashboard(filtered, now, days, sample, isAll),
    gaugeMax,
    turnGaugeMax: niceScaleMax(
      Math.max(latest?.turnThroughputTPS ?? 0, groupMedian24h),
    ),
    isAll,
    mode,
    selection,
    activeKey,
    liveDriven,
    scopeRecords,
    scopeTools,
    liveLatest,
    hero,
    heroTurn: hero.source === "turn" ? latestResponseTurn : undefined,
    heroRelative: hero.at === null ? null : relativeTime(hero.at, now),
    responseDelta,
    responseInRange,
    responseSummary: summarize(responseInRange).response,
    responseTotals: {
      turns: responseInRange.filter((m) => responseSpeed(m) !== null).length,
      responses: responseInRange.reduce((sum, m) => sum + (m.responseCount ?? 0), 0),
    },
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
    recentResponse15m: summarize(period(scopeRecords, now - 900000, now + 1)).response,
    change: {
      throughput: change(last24h.throughput, previous24h.throughput),
      ttft: change(last24h.ttft, previous24h.ttft),
      response: change(response24.response, previousResponse24.response),
    },
    signals: {
      throughput: signal(selected, now, "throughput"),
      ttft: signal(selected, now, "ttft"),
    },
    /** Rows of the full-history table: every filtered cohort when comparing, else the model's turns. */
    historyRows: period(isAll ? filtered : scopeRecords, rangeStart, now + 1),
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
