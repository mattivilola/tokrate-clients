import { communityId, type LiveResponse, type Metric } from "../metrics";
import { parseSelection } from "../response";
import type {
  Board,
  Bridge,
  Settings,
  SettingsPatch,
  Snapshot,
  SourceId,
  SourceStatus,
  UpdatePreferences,
  UpdateSummary,
} from "./types";

/**
 * Browser-only preview of the tray UI with synthetic data. It never reads logs and never
 * talks to the network. Scenario/view query parameters are honoured in development builds only:
 *   ?scenario=default|empty|onboarding|sharing|update
 *   ?view=home|compare|settings|history
 */
export type PreviewScenario =
  | "default"
  | "empty"
  | "onboarding"
  | "sharing"
  | "update";
export type PreviewView = "home" | "compare" | "settings" | "history";

export interface PreviewParams {
  scenario: PreviewScenario;
  view: PreviewView;
}

const SCENARIOS: PreviewScenario[] = [
  "default",
  "empty",
  "onboarding",
  "sharing",
  "update",
];
const VIEWS: PreviewView[] = ["home", "compare", "settings", "history"];

export function previewParams(search: string): PreviewParams {
  if (!import.meta.env.DEV) return { scenario: "default", view: "home" };
  const q = new URLSearchParams(search);
  const scenario = q.get("scenario") as PreviewScenario;
  const view = q.get("view") as PreviewView;
  return {
    scenario: SCENARIOS.includes(scenario) ? scenario : "default",
    view: VIEWS.includes(view) ? view : "home",
  };
}

const MINUTE = 60000;
function rng(seed: number) {
  return () => {
    seed = (seed * 1664525 + 1013904223) % 4294967296;
    return seed / 4294967296;
  };
}

interface Series {
  model: string;
  client: string;
  effort: string;
  provider: string;
  parser: string;
  metricVersion: string;
  sourceKind: string;
  everyMinutes: number;
  base: number;
  spread: number;
  ttft: boolean;
  offset: number;
  /** Response speed relative to the whole-turn speed; tools and waiting dilute the turn. */
  responseFactor: number;
  /** Scales the synthetic output tokens so models differ in tokens per request. */
  tokenFactor: number;
  /** Share of primary turns that started subagent work (its tokens come on top of the output). */
  delegates: number;
}

const SERIES: Series[] = [
  {
    model: "Example model A",
    client: "codex",
    effort: "high",
    provider: "openai",
    parser: "codex-rollout-v2",
    metricVersion: "turn-v1",
    sourceKind: "primary",
    everyMinutes: 47,
    base: 44,
    spread: 22,
    ttft: true,
    offset: 4,
    responseFactor: 2.3,
    tokenFactor: 1,
    delegates: 0.15,
  },
  {
    model: "Example model B",
    client: "codex",
    effort: "medium",
    provider: "openai",
    parser: "codex-rollout-v2",
    metricVersion: "turn-v1",
    sourceKind: "primary",
    everyMinutes: 83,
    base: 71,
    spread: 28,
    ttft: true,
    offset: 19,
    responseFactor: 1.9,
    tokenFactor: 0.6,
    delegates: 0.0,
  },
  {
    model: "Example Claude model",
    client: "claude-code",
    effort: "high",
    provider: "anthropic",
    parser: "claude-transcript-v4",
    metricVersion: "claude-observed-turn-v1",
    sourceKind: "primary",
    everyMinutes: 121,
    base: 58,
    spread: 20,
    ttft: false,
    offset: 33,
    responseFactor: 2.1,
    tokenFactor: 1.8,
    delegates: 0.4,
  },
  {
    model: "Example Claude model",
    client: "claude-code",
    effort: "high",
    provider: "anthropic",
    parser: "claude-transcript-v4",
    metricVersion: "claude-observed-subagent-turn-v1",
    sourceKind: "subagent",
    everyMinutes: 150,
    base: 36,
    spread: 14,
    ttft: false,
    offset: 52,
    responseFactor: 3.0,
    tokenFactor: 0.5,
    delegates: 0.0,
  },
  {
    model: "Example Gemini model",
    client: "antigravity",
    effort: "medium",
    provider: "google",
    parser: "antigravity-conversation-v1",
    metricVersion: "antigravity-observed-execution-v1",
    sourceKind: "primary",
    everyMinutes: 97,
    base: 52,
    spread: 18,
    ttft: false,
    offset: 41,
    responseFactor: 2.0,
    tokenFactor: 1.2,
    delegates: 0.0,
  },
  {
    // OpenCode keeps the raw provider id (here a gateway) locally.
    model: "moonshotai/kimi-k2.5",
    client: "opencode",
    effort: "medium",
    provider: "openrouter",
    parser: "opencode-db-v1",
    metricVersion: "opencode-observed-turn-v1",
    sourceKind: "primary",
    everyMinutes: 61,
    base: 38,
    spread: 14,
    ttft: false,
    offset: 27,
    responseFactor: 1.8,
    tokenFactor: 0.8,
    delegates: 0.1,
  },
];

export function previewRecords(now: number): Metric[] {
  const records: Metric[] = [];
  SERIES.forEach((s, index) => {
    const random = rng(1000 + index * 77);
    const count = Math.floor((7 * 24 * 60) / s.everyMinutes);
    for (let i = 0; i < count; i++) {
      const jitter = random();
      const tps = Math.max(
        6,
        s.base +
          (random() - 0.5) * s.spread * 2 +
          Math.sin(i / 5 + index) * s.spread * 0.4,
      );
      const outputTokens = Math.round((250 + jitter * 900) * s.tokenFactor);
      // Subagent records never carry delegated tokens; a primary turn is final with 0 or the
      // output of the subagent work it started.
      const delegatedOutputTokens =
        s.sourceKind === "subagent"
          ? null
          : random() < s.delegates
            ? Math.round(outputTokens * (0.4 + random() * 1.2))
            : 0;
      const responseCount = 2 + Math.floor(random() * 4);
      const responseTokens = Math.round(outputTokens * (0.7 + random() * 0.25));
      const responseTps = tps * s.responseFactor * (0.85 + random() * 0.3);
      records.push({
        id: `demo-${index}-${i}`,
        completedAt: new Date(
          now - (s.offset + i * s.everyMinutes) * MINUTE - jitter * 9 * MINUTE,
        ).toISOString(),
        model: s.model,
        provider: s.provider,
        client: s.client,
        parserVersion: s.parser,
        metricVersion: s.metricVersion,
        sourceKind: s.sourceKind,
        clientVersion: "example",
        reasoningEffort: s.effort,
        outputTokens,
        reasoningOutputTokens: Math.round(outputTokens * (0.2 + random() * 0.4)),
        delegatedOutputTokens,
        durationSeconds: outputTokens / tps,
        codexTTFTSeconds: s.ttft ? 1.2 + random() * 2.4 : null,
        turnThroughputTPS: tps,
        responseOutputTokens: responseTokens,
        responseDurationSeconds: responseTokens / responseTps,
        responseCount,
      });
    }
  });
  return records.sort(
    (a, b) => Date.parse(b.completedAt) - Date.parse(a.completedAt),
  );
}

/** A few responses completed in the last minutes, newest model first in the burst. */
export function previewLive(now: number): LiveResponse[] {
  const response = (
    id: string,
    minutesAgo: number,
    model: string,
    client: string,
    provider: string,
    sourceKind: string,
    tokens: number,
    tps: number,
  ): LiveResponse => ({
    id,
    completedAt: new Date(now - minutesAgo * MINUTE).toISOString(),
    model,
    provider,
    client,
    sourceKind,
    metricVersion: "response-v1",
    reasoningEffort: "high",
    outputTokens: tokens,
    durationSeconds: tokens / tps,
  });
  const claude = (id: string, minutesAgo: number, tokens: number, tps: number) =>
    response(id, minutesAgo, "Example Claude model", "claude-code", "anthropic", "primary", tokens, tps);
  return [
    claude("live-1", 7.5, 640, 118),
    claude("live-2", 5.2, 410, 126),
    response("live-3", 4.1, "Example model A", "codex", "openai", "primary", 300, 58),
    claude("live-4", 3.3, 880, 109),
    claude("live-5", 1.6, 520, 121),
    claude("live-6", 0.4, 760, 133),
  ];
}

/** Dominant live model of the last ten minutes, restricted to one tool for `auto:<tool>`. */
function previewActive(live: LiveResponse[], selection: string, now: number) {
  const mode = parseSelection(selection);
  if (mode.kind !== "auto") return null;
  const tokens = new Map<string, { model: string | null; provider: string | null; tokens: number }>();
  for (const r of live) {
    if (now - Date.parse(r.completedAt) > 10 * MINUTE) continue;
    if (mode.tool && r.client !== mode.tool) continue;
    const key = `${r.model}|${r.provider}`;
    const entry = tokens.get(key) ?? { model: r.model, provider: r.provider, tokens: 0 };
    entry.tokens += r.outputTokens;
    tokens.set(key, entry);
  }
  const best = [...tokens.values()].sort((a, b) => b.tokens - a.tokens)[0];
  return best ? { model: best.model, provider: best.provider } : null;
}

const DEFAULT_ROOTS: Record<SourceId, string> = {
  codex: "~/.codex/sessions",
  "claude-code": "~/.claude/projects",
  "grok-build": "~/.grok/sessions",
  antigravity: "~/.gemini",
  opencode: "~/.local/share/opencode",
};

function previewBoard(records: Metric[]): Board {
  const seen = new Map<string, Metric>();
  for (const m of records)
    if (!seen.has(communityId(m))) seen.set(communityId(m), m);
  return {
    window: "24h",
    state: "ok",
    dataAsOf: new Date().toISOString(),
    methodology: { publicationMode: "early_data" },
    cohorts: [...seen].map(([id, m], i) => ({
      id,
      model: m.model,
      reasoningEffort: m.reasoningEffort,
      client: m.client ?? "codex",
      provider: m.provider,
      contributors: 2 + i,
      turns: 40 + i * 13,
      throughputTurns: 40 + i * 13,
      ttftTurns: m.codexTTFTSeconds === null ? 0 : 30,
      medianThroughput: [46, 69, 55, 33][i % 4],
      medianTtftMs: m.codexTTFTSeconds === null ? null : 2100,
      signals: { throughput: { state: "stable" }, ttft: { state: "stable" } },
    })),
    alerts: [],
  };
}

export function createPreviewBridge(params: PreviewParams): Bridge {
  const now = Date.now();
  const records = params.scenario === "empty" ? [] : previewRecords(now);
  const settings: Settings = {
    sharing: params.scenario === "sharing",
    monitoring: true,
    showSpeed: true,
    showProviderBadge: true,
    selection: params.view === "compare" ? "all" : "auto",
    days: 1,
    root: "",
    claudeRoot: "",
    grokRoot: "",
    antigravityRoot: "",
    opencodeRoot: "",
  };
  const custom: Partial<Record<SourceId, string>> = {};
  const sources = (): SourceStatus[] =>
    (Object.keys(DEFAULT_ROOTS) as SourceId[]).map((id) => ({
      id,
      root: custom[id] ?? DEFAULT_ROOTS[id],
      isDefault: custom[id] === undefined,
      found: params.scenario === "empty" ? id === "codex" : id !== "grok-build",
    }));
  let snap: Snapshot = {
    settings,
    consentPromptRequired: params.scenario === "onboarding",
    records,
    status: settings.sharing
      ? "Preview: sharing simulated"
      : "Preview: local only",
    monitorStatus: "Preview: monitoring simulated",
    pending: settings.sharing ? 2 : 0,
    board: settings.sharing ? previewBoard(records) : null,
    revision: 1,
    recordsChanged: true,
  };
  const live = params.scenario === "empty" ? [] : previewLive(now);
  const read = (since: number | null): Snapshot => ({
    ...snap,
    sources: sources(),
    live,
    active: previewActive(live, snap.settings.selection, Date.now()),
    records: since === snap.revision ? [] : snap.records,
    recordsChanged: since !== snap.revision,
  });
  const update: UpdateSummary | null =
    params.scenario === "update"
      ? {
          version: "0.2.0",
          body: "Synthetic preview update. Nothing is downloaded.",
        }
      : null;
  const prefs: UpdatePreferences = {
    automaticChecks: true,
    mode: "native",
    settingsWarning: null,
    currentVersion: "preview",
  };
  return {
    native: false,
    snapshot: async (since) => read(since),
    updateSettings: async (patch: SettingsPatch) => {
      if (patch.sharing === true)
        throw new Error(
          "Community sharing requires the current informed consent",
        );
      snap = { ...snap, settings: { ...snap.settings, ...patch } };
      if (patch.sharing === false)
        snap = {
          ...snap,
          board: null,
          pending: 0,
          status: "Preview: local only",
        };
      return read(null);
    },
    recordSharingConsent: async (accepted) => {
      snap = {
        ...snap,
        consentPromptRequired: false,
        settings: { ...snap.settings, sharing: accepted },
        board: accepted ? previewBoard(snap.records) : null,
        status: accepted ? "Preview: sharing simulated" : "Preview: local only",
      };
      return read(null);
    },
    retrySharing: async () => read(null),
    chooseFolder: async (source) => {
      custom[source] = "~/Example/log-folder";
      return read(null);
    },
    resetFolder: async (source) => {
      delete custom[source];
      return read(null);
    },
    openWebsite: async (page) => {
      const path = {
        home: "",
        privacy: "/privacy",
        terms: "/terms",
        "desktop-downloads": "/download",
      }[page];
      window.open(
        `https://tokrate.dev${path}`,
        "_blank",
        "noopener,noreferrer",
      );
    },
    openHistory: async () => {
      const url = new URL(window.location.href);
      url.searchParams.set("view", "history");
      window.open(url, "_blank", "noopener,noreferrer");
    },
    hideFlyout: async () => {},
    quit: async () => {},
    smokeComplete: async () => {},
    updatePreferences: async () => prefs,
    setAutomaticUpdateChecks: async (enabled) => ({
      ...prefs,
      automaticChecks: enabled,
    }),
    checkUpdate: async () => ({ started: true, update }),
    installUpdate: async (onEvent) => {
      onEvent({ event: "Started", data: { contentLength: 100 } });
      for (let i = 0; i < 10; i++) {
        await new Promise((resolve) => setTimeout(resolve, 150));
        onEvent({ event: "Progress", data: { chunkLength: 10 } });
      }
      onEvent({ event: "Finished" });
    },
    restartAfterUpdate: async () => {},
  };
}
