import { communityId, type Metric } from "../metrics";
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
}

const SERIES: Series[] = [
  {
    model: "Example model A",
    client: "codex",
    effort: "high",
    provider: "openai",
    parser: "codex-rollout-v1",
    metricVersion: "turn-v1",
    sourceKind: "primary",
    everyMinutes: 47,
    base: 44,
    spread: 22,
    ttft: true,
    offset: 4,
  },
  {
    model: "Example model B",
    client: "codex",
    effort: "medium",
    provider: "openai",
    parser: "codex-rollout-v1",
    metricVersion: "turn-v1",
    sourceKind: "primary",
    everyMinutes: 83,
    base: 71,
    spread: 28,
    ttft: true,
    offset: 19,
  },
  {
    model: "Example Claude model",
    client: "claude-code",
    effort: "high",
    provider: "anthropic",
    parser: "claude-transcript-v3",
    metricVersion: "claude-observed-turn-v1",
    sourceKind: "primary",
    everyMinutes: 121,
    base: 58,
    spread: 20,
    ttft: false,
    offset: 33,
  },
  {
    model: "Example Claude model",
    client: "claude-code",
    effort: "high",
    provider: "unknown",
    parser: "claude-transcript-v3",
    metricVersion: "claude-observed-subagent-turn-v1",
    sourceKind: "subagent",
    everyMinutes: 150,
    base: 36,
    spread: 14,
    ttft: false,
    offset: 52,
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
      const outputTokens = Math.round(250 + jitter * 900);
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
        durationSeconds: outputTokens / tps,
        codexTTFTSeconds: s.ttft ? 1.2 + random() * 2.4 : null,
        turnThroughputTPS: tps,
      });
    }
  });
  return records.sort(
    (a, b) => Date.parse(b.completedAt) - Date.parse(a.completedAt),
  );
}

const DEFAULT_ROOTS: Record<SourceId, string> = {
  codex: "~/.codex/sessions",
  "claude-code": "~/.claude/projects",
  "grok-build": "~/.grok/sessions",
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
    selection: params.view === "compare" ? "all" : "latest",
    days: 1,
    root: "",
    claudeRoot: "",
    grokRoot: "",
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
  const read = (since: number | null): Snapshot => ({
    ...snap,
    sources: sources(),
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
