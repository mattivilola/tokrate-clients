import {
  DAY,
  client,
  isSubagent,
  niceScaleMax,
  period,
  providerLabel,
  responseSpeed,
  stats,
  type LiveResponse,
  type Metric,
  type Stats,
} from "./metrics";

/** Responses of the last ten minutes feed the live value: the median of the newest five. */
export const LIVE_WINDOW_MS = 10 * 60000;
export const LIVE_COUNT = 5;

/** The model an Auto selection currently follows (from the live stream or the newest turn). */
export interface ModelKey {
  model: string | null;
  provider: string | null;
}

export const sameModel = (
  m: { model?: string | null; provider?: string | null },
  key: ModelKey,
) =>
  (m.model ?? null) === (key.model ?? null) &&
  (m.provider ?? "unknown") === (key.provider ?? "unknown");

// --- selection ---------------------------------------------------------------------------------

export type ToolId = "codex" | "claude-code" | "grok-build" | "antigravity" | "opencode" | "kimi-code";
const TOOLS: ToolId[] = [
  "codex",
  "claude-code",
  "grok-build",
  "antigravity",
  "opencode",
  "kimi-code",
];

/** The persisted `selection` setting; `latest` (before 0.1.14) means `auto`. */
export type SelectionMode =
  | { kind: "auto"; tool: ToolId | null }
  | { kind: "all" }
  | { kind: "model"; key: ModelKey }
  | { kind: "cohort"; key: string; model: string | null; provider: string | null; client: string | null };

export function parseSelection(selection: string): SelectionMode {
  if (selection === "all") return { kind: "all" };
  if (selection.startsWith("auto:")) {
    const tool = selection.slice(5) as ToolId;
    return { kind: "auto", tool: TOOLS.includes(tool) ? tool : null };
  }
  if (selection.startsWith("model:")) {
    try {
      const parts: unknown = JSON.parse(selection.slice(6));
      if (Array.isArray(parts) && parts.length === 2)
        return {
          kind: "model",
          key: {
            model: typeof parts[0] === "string" ? parts[0] : null,
            provider: typeof parts[1] === "string" ? parts[1] : null,
          },
        };
    } catch {
      /* falls through to auto */
    }
    return { kind: "auto", tool: null };
  }
  if (selection.startsWith("[")) {
    try {
      const parts: unknown = JSON.parse(selection);
      if (Array.isArray(parts) && parts.length === 9) {
        const text = (v: unknown) => (typeof v === "string" ? v : null);
        return {
          kind: "cohort",
          key: selection,
          client: text(parts[0]),
          model: text(parts[4]),
          provider: text(parts[5]),
        };
      }
    } catch {
      /* falls through to auto */
    }
  }
  return { kind: "auto", tool: null };
}

export const autoSelection = (tool: ToolId | null) =>
  tool ? `auto:${tool}` : "auto";
export const modelSelection = (key: ModelKey) =>
  `model:${JSON.stringify([key.model, key.provider ?? "unknown"])}`;

/** With no live responses: the newest turn with response data, else the newest turn. */
export function fallbackModel(records: Metric[]): ModelKey | null {
  const chosen = records.find((m) => responseSpeed(m) !== null) ?? records[0];
  return chosen
    ? { model: chosen.model ?? null, provider: chosen.provider ?? "unknown" }
    : null;
}

// --- live stream -------------------------------------------------------------------------------

export interface LiveScope extends ModelKey {
  client: string | null;
}

export interface LiveValue {
  speed: number;
  count: number;
  lastAt: number;
}

const liveSpeed = (r: LiveResponse) => r.outputTokens / r.durationSeconds;

/** Median speed of the newest five matching responses finished within the last ten minutes. */
export function liveValue(
  live: LiveResponse[],
  scope: LiveScope,
  now: number,
): LiveValue | null {
  const newest = live
    .map((r) => ({ r, at: Date.parse(r.completedAt) }))
    .filter(
      ({ r, at }) =>
        Number.isFinite(at) &&
        at >= now - LIVE_WINDOW_MS &&
        at <= now &&
        r.durationSeconds > 0 &&
        sameModel(r, scope) &&
        (scope.client === null || r.client === scope.client),
    )
    .sort((a, b) => b.at - a.at)
    .slice(0, LIVE_COUNT);
  if (!newest.length) return null;
  const speed = stats(newest.map(({ r }) => liveSpeed(r))).median;
  return speed === null
    ? null
    : { speed, count: newest.length, lastAt: newest[0].at };
}

// --- provider badge ----------------------------------------------------------------------------

export type BadgeFamily = "anthropic" | "openai" | "xai" | "google" | "moonshot" | "unknown";

/** Explicit provider evidence wins; otherwise the model family decides (letters only, no logos). */
export function badgeFamily(
  model: string | null | undefined,
  provider: string | null | undefined,
): BadgeFamily {
  if (provider === "openai") return "openai";
  if (provider === "xai") return "xai";
  if (provider === "google") return "google";
  if (provider === "moonshot") return "moonshot";
  if (provider === "anthropic") return "anthropic";
  const name = (model ?? "").toLowerCase();
  if (name.startsWith("claude-")) return "anthropic";
  if (name.startsWith("gpt-") || name.includes("codex") || /^o\d/.test(name))
    return "openai";
  if (name.startsWith("grok-")) return "xai";
  if (name.startsWith("gemini-")) return "google";
  if (name.startsWith("kimi-") || /^k\d/.test(name)) return "moonshot";
  return "unknown";
}

export const BADGE_LETTER: Record<BadgeFamily, string> = {
  anthropic: "A",
  openai: "O",
  xai: "X",
  google: "G",
  moonshot: "M",
  unknown: "",
};
export const BADGE_LABEL: Record<BadgeFamily, string> = {
  anthropic: "Anthropic",
  openai: "OpenAI",
  xai: "xAI",
  google: "Google",
  moonshot: "Moonshot AI",
  unknown: "Unknown provider",
};

// --- response-speed model rows -----------------------------------------------------------------

export interface ModelSpeedRow {
  /** `model:` selection string that pins this row. */
  key: string;
  model: ModelKey;
  /** Median of the per-turn response speeds in the period; null without response data. */
  median: number | null;
  /** Turns with response data in the period. */
  turns: number;
  /** Qualifying responses behind those turns. */
  responses: number;
  tools: string[];
  hasSubagent: boolean;
  latestAt: number;
  /** Turns without response timing (for example Grok Build) in the period. */
  untimed: number;
}

const TOOL_ORDER = ["codex", "claude-code", "grok-build", "antigravity", "opencode", "kimi-code"];

/**
 * One row per model and provider across coding tools and subagent/primary work. Response speed
 * is one definition everywhere, so pooling these turns is valid.
 */
export function modelSpeedRows(
  records: Metric[],
  start: number,
  end: number,
): ModelSpeedRow[] {
  const groups = new Map<string, Metric[]>();
  for (const m of records) {
    const key = JSON.stringify([m.model ?? null, m.provider ?? "unknown"]);
    groups.set(key, [...(groups.get(key) ?? []), m]);
  }
  const rows = [...groups.values()].map((list): ModelSpeedRow => {
    const inPeriod = period(list, start, end);
    const timed = inPeriod.filter((m) => responseSpeed(m) !== null);
    const model: ModelKey = {
      model: list[0].model ?? null,
      provider: list[0].provider ?? "unknown",
    };
    return {
      key: modelSelection(model),
      model,
      median: stats(timed.flatMap((m) => responseSpeed(m) ?? [])).median,
      turns: timed.length,
      responses: timed.reduce((sum, m) => sum + (m.responseCount ?? 0), 0),
      tools: TOOL_ORDER.filter((id) => list.some((m) => client(m) === id)),
      hasSubagent: list.some(isSubagent),
      latestAt: list.reduce((max, m) => Math.max(max, Date.parse(m.completedAt)), 0),
      untimed: inPeriod.length - timed.length,
    };
  });
  return rows;
}

export type ModelSort = "speed" | "recent";

/** Fastest first (models without response data last), or most recently active first. */
export function sortModelRows(rows: ModelSpeedRow[], sort: ModelSort): ModelSpeedRow[] {
  return [...rows].sort((a, b) =>
    sort === "recent"
      ? b.latestAt - a.latestAt
      : (b.median ?? -1) - (a.median ?? -1) || b.latestAt - a.latestAt,
  );
}

/** Median response speed over the last 24 hours of a record list. */
export const response24h = (records: Metric[], now: number): Stats =>
  stats(
    period(records, now - DAY, now + 1).flatMap((m) => responseSpeed(m) ?? []),
  );

export const providerName = providerLabel;


/** Shared mini-bar scale of a row list: the nice ceiling of 1.25 x the largest median. */
export const niceMedianMax = (rows: ModelSpeedRow[]) =>
  niceScaleMax(rows.reduce((max, row) => Math.max(max, row.median ?? 0), 0));
