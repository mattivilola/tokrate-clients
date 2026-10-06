import { describe, expect, it } from "vitest";
import {
  DAY,
  GROK_RESPONSE_EXPLANATION,
  GROK_RESPONSE_NOTE,
  cohort,
  isGrokBuild,
  type LiveResponse,
  type Metric,
} from "../metrics";
import { pickerAccessibleLabel, pickerLabel } from "../components/Header";
import { heroCaption } from "../components/Hero";
import { chartCopy } from "../components/Trend";
import { CLIENT_ORDER, buildDashboard, communityLine } from "./dashboard";
import {
  DELEGATED_NOTICE,
  PROMPT_CACHE_NOTICE,
  SURFACE_NOTICE,
  buildSentExample,
} from "../components/SharingChoice";
import { EFFICIENCY_EXPLANATION, EFFICIENCY_INSUFFICIENT } from "../metrics";
import { PROVIDER_TITLES, SOURCE_TITLES, folderName, readout, signedPercent } from "./format";
import { monitoringState, sharingState } from "./status";
import { niceCeil } from "../components/TrendChart";
import { GAUGE } from "../components/Gauge";
import { niceScaleMax } from "../metrics";
import type { Snapshot } from "../store/types";

const NOW = Date.parse("2026-10-04T12:00:00Z");
const turn = (id: string, minutesAgo: number, tps: number, p: Partial<Metric> = {}): Metric => ({
  id,
  completedAt: new Date(NOW - minutesAgo * 60000).toISOString(),
  model: "model-a",
  provider: "openai",
  clientVersion: "1",
  reasoningEffort: "high",
  outputTokens: 200,
  durationSeconds: 200 / tps,
  codexTTFTSeconds: 2,
  turnThroughputTPS: tps,
  ...p,
});
const input = (records: Metric[], over = {}) => ({
  records,
  selection: "auto",
  days: 1,
  tool: "all" as const,
  provider: "all" as const,
  now: NOW,
  sort: "recent" as const,
  ...over,
});

describe("dashboard model", () => {
  it("selects the latest cohort and compares the latest turn with its own 24 h median", () => {
    const records = [turn("1", 5, 60), turn("2", 60, 50), turn("3", 120, 50), turn("4", 180, 50)];
    const d = buildDashboard(input(records));
    expect(d.latest?.id).toBe("1");
    expect(d.delta?.percent).toBeGreaterThan(0);
    expect(d.latestRelative).toBe("5 min ago");
  });
  it("hides the delta below three turns", () => {
    expect(buildDashboard(input([turn("1", 5, 60), turn("2", 60, 50)])).delta).toBeNull();
  });
  it("falls back to the latest cohort when the saved selection has expired", () => {
    const records = [turn("1", 5, 60)];
    const d = buildDashboard(input(records, { selection: cohort(turn("x", 1, 1, { model: "gone" })) }));
    expect(d.selection).toBe("auto");
    expect(d.sample?.id).toBe("1");
  });
  it("keeps all-models mode free of pooled values", () => {
    const d = buildDashboard(input([turn("1", 5, 60), turn("2", 6, 30, { model: "model-b" })], { selection: "all" }));
    expect(d.isAll).toBe(true);
    expect(d.selected).toEqual([]);
    expect(d.cohorts).toHaveLength(2);
  });
  it("applies coding-tool and provider filters", () => {
    const records = [turn("1", 5, 60), turn("2", 6, 30, { client: "claude-code", provider: "unknown", codexTTFTSeconds: null })];
    expect(buildDashboard(input(records, { tool: "claude-code" })).cohorts).toHaveLength(1);
    expect(buildDashboard(input(records, { provider: "openai" })).filtered.map((m) => m.id)).toEqual(["1"]);
  });
  it("filters Claude Code turns by Bedrock and Vertex providers", () => {
    const claude = (id: string, provider: string) =>
      turn(id, 5, 60, { client: "claude-code", provider, codexTTFTSeconds: null });
    const records = [claude("a", "anthropic"), claude("b", "amazon-bedrock"), claude("c", "google-vertex")];
    for (const [provider, id] of [["anthropic", "a"], ["amazon-bedrock", "b"], ["google-vertex", "c"]] as const) {
      expect(buildDashboard(input(records, { provider })).filtered.map((m) => m.id)).toEqual([id]);
    }
  });
  it("lists Antigravity among the coding tools", () => {
    expect(SOURCE_TITLES.antigravity).toBe("Antigravity");
    expect(CLIENT_ORDER).toContain("antigravity");
    expect(CLIENT_ORDER).toContain("opencode");
    expect(SOURCE_TITLES.opencode).toBe("OpenCode");
  });
  it("offers every attributable provider in the filter", () => {
    expect(PROVIDER_TITLES).toEqual({
      openai: "OpenAI",
      anthropic: "Anthropic",
      "amazon-bedrock": "Amazon Bedrock",
      "google-vertex": "Google Vertex AI",
      xai: "xAI",
      google: "Google",
      unknown: "Unknown route",
    });
  });
  it("ignores turns outside the 7 day retention and in the future", () => {
    const records = [turn("old", 8 * 24 * 60, 10), turn("future", -10, 10)];
    expect(buildDashboard(input(records)).hasRecords).toBe(false);
    expect(DAY).toBe(86400000);
  });
  it("positions you against the community only for a matching window", () => {
    const records = [turn("1", 5, 60), turn("2", 60, 60), turn("3", 120, 60)];
    const d = buildDashboard(input(records));
    const id = JSON.stringify(["model-a", "openai", "1", "codex-rollout-v1", "turn-v1", "high", "codex"]);
    const board = { window: "24h", cohorts: [{ id, medianThroughput: 50 }] };
    expect(communityLine(board, d)?.position).toBe(20);
    expect(communityLine({ ...board, window: "7d" }, d)?.position).toBeNull();
    expect(communityLine({ ...board, state: "stale" }, d)?.caution).toBe("Older data");
    expect(communityLine({ cohorts: [] }, d)).toBeNull();
  });
});

describe("gauge", () => {
  it("never lets the needle or hub reach the readout at any value", () => {
    for (const fraction of [0, 0.02, 0.25, 0.5, 0.75, 1]) {
      const angle = ((150 + fraction * 240) * Math.PI) / 180;
      const tipY = GAUGE.cy + GAUGE.needleLength * Math.sin(angle);
      expect(tipY + 2).toBeLessThan(GAUGE.readoutTop);
    }
    expect(GAUGE.cy + GAUGE.hubRadius).toBeLessThan(GAUGE.readoutTop);
    expect(GAUGE.needleLength).toBe(GAUGE.radius - 14);
  });
  it("scales the hero by its own measurement group only", () => {
    const sub = turn("s", 5, 400, { client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent", codexTTFTSeconds: null });
    const codex = [turn("1", 5, 60), turn("2", 60, 80), turn("3", 120, 40)];
    const d = buildDashboard(input([...codex, sub]));
    // Latest codex value 60, group median 60 -> 1.25 x 60 = 75.
    expect(d.latest?.client ?? "codex").toBe("codex");
    expect(d.turnGaugeMax).toBe(75);
    const only = buildDashboard(input([sub], { selection: "auto" }));
    expect(only.turnGaugeMax).toBe(500);
  });
  it("groups models by measurement group, most recent group first", () => {
    const sub = turn("s", 1, 30, { client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-subagent-turn-v1", sourceKind: "subagent", codexTTFTSeconds: null });
    const claude = turn("c", 2, 70, { client: "claude-code", parserVersion: "claude-transcript-v2", metricVersion: "claude-observed-turn-v1", sourceKind: "primary", codexTTFTSeconds: null });
    const codexA = turn("a", 3, 20);
    const codexB = turn("b", 4, 90, { model: "model-b" });
    const d = buildDashboard(input([sub, claude, codexA, codexB], { sort: "throughput" }));
    expect(d.groups.map((g) => g.title)).toEqual([
      "Claude Code · Subagent turn speed",
      "Claude Code · Turn speed",
      "Codex · Turn speed",
    ]);
    const codex = d.compareGroups.find((g) => g.title === "Codex · Turn speed")!;
    expect(codex.rows.map((r) => r.sample.id)).toEqual(["b", "a"]);
    expect(codex.max).toBe(150);
    expect(d.groups[0].max).toBe(50);
    expect(codex.definition).toMatch("Completed Codex turn");
  });
});

describe("formatting and scales", () => {
  it("scales the gauge and chart axes", () => {
    expect(niceScaleMax(null)).toBe(20);
    expect(niceScaleMax(0)).toBe(20);
    expect(niceScaleMax(16)).toBe(20);
    expect(niceScaleMax(17)).toBe(25);
    expect(niceScaleMax(40)).toBe(50);
    expect(niceScaleMax(65.2)).toBe(100);
    expect(niceScaleMax(80)).toBe(100);
    expect(niceScaleMax(81)).toBe(150);
    expect(niceScaleMax(800)).toBe(1000);
    expect(niceScaleMax(900)).toBe(1250);
    expect(niceCeil(87)).toBe(100);
    expect(niceCeil(41)).toBe(50);
    expect(niceCeil(7.2)).toBe(10);
    expect(niceCeil(0)).toBe(1);
  });
  it("formats numbers, percentages and folders compactly", () => {
    expect(readout(65.234)).toBe("65.2");
    expect(readout(123.4)).toBe("123");
    expect(readout(null)).toBe("—");
    expect(signedPercent(11.6)).toBe("+12%");
    expect(signedPercent(-8)).toBe("−8%");
    expect(signedPercent(0.2)).toBe("0%");
    expect(folderName("/Users/me/.claude/projects/")).toBe(".claude/projects");
    expect(folderName("C:\\Users\\me\\.codex\\sessions")).toBe(".codex/sessions");
  });
  it("labels monitoring and sharing like the Mac footer", () => {
    const base = {
      settings: { sharing: false, monitoring: true },
      consentPromptRequired: false,
      status: "Local only",
      monitorStatus: "Monitoring 3 sources",
    } as unknown as Snapshot;
    expect(sharingState(base).label).toBe("Local only");
    expect(sharingState({ ...base, consentPromptRequired: true }).label).toBe("Sharing choice pending");
    const on = { ...base, settings: { ...base.settings, sharing: true } } as Snapshot;
    expect(sharingState({ ...on, status: "Sharing new turns" }).label).toBe("Sharing on");
    expect(sharingState({ ...on, status: "Upload unavailable." }).tone).toBe("warn");
    expect(monitoringState(base).tone).toBe("good");
    expect(monitoringState({ ...base, monitorStatus: "A source folder could not be read." }).tone).toBe("warn");
    expect(monitoringState({ ...base, settings: { ...base.settings, monitoring: false } }).label).toBe("Paused");
  });
});

// --- response speed -----------------------------------------------------------------------------

/** A turn whose qualifying responses ran at `rtps` tokens per second. */
const rturn = (id: string, minutesAgo: number, rtps: number, p: Partial<Metric> = {}): Metric =>
  turn(id, minutesAgo, 20, { responseOutputTokens: 600, responseDurationSeconds: 600 / rtps, responseCount: 3, ...p });
const claudeTurn = (id: string, minutesAgo: number, rtps: number, p: Partial<Metric> = {}) =>
  rturn(id, minutesAgo, rtps, {
    client: "claude-code",
    model: "claude-opus-5-5",
    provider: "anthropic",
    parserVersion: "claude-transcript-v4",
    metricVersion: "claude-observed-turn-v1",
    sourceKind: "primary",
    codexTTFTSeconds: null,
    ...p,
  });
const liveResponse = (id: string, minutesAgo: number, tps: number, p: Partial<LiveResponse> = {}): LiveResponse => ({
  id,
  completedAt: new Date(NOW - minutesAgo * 60000).toISOString(),
  model: "claude-opus-5-5",
  provider: "anthropic",
  client: "claude-code",
  sourceKind: "primary",
  metricVersion: "response-v1",
  reasoningEffort: "high",
  outputTokens: 500,
  durationSeconds: 500 / tps,
  ...p,
});

describe("response speed hero", () => {
  const records = [claudeTurn("c1", 30, 100), claudeTurn("c2", 90, 100), claudeTurn("c3", 150, 100), rturn("x1", 40, 40)];
  it("shows the median of the last five live responses and its caption", () => {
    const live = [10, 20, 30, 40, 50, 60].map((tps, i) => liveResponse(`l${i}`, 8 - i * 0.5, tps));
    const d = buildDashboard(input(records, { live, active: { model: "claude-opus-5-5", provider: "anthropic" } }));
    // Newest five are the last five: 20..60 tok/s -> median 40.
    expect(d.hero).toMatchObject({ source: "live", count: 5 });
    expect(d.hero.value).toBeCloseTo(40, 6);
    expect(heroCaption(d)).toBe("last 5 responses · just now".replace("just now", d.heroRelative!));
    expect(d.liveDriven).toBe(true);
    expect(pickerLabel(d)).toBe("Auto · claude-opus-5-5");
    // 24 h response-speed median of the model is 100 tok/s: the live 40 is 60% below it.
    expect(d.responseDelta?.percent).toBeCloseTo(-60, 6);
  });
  it("ignores live responses older than ten minutes and falls back to the newest turn", () => {
    const live = [liveResponse("old", 11, 50)];
    const d = buildDashboard(input(records, { live, active: null }));
    expect(d.hero.source).toBe("turn");
    expect(d.hero.value).toBeCloseTo(100, 6);
    expect(d.activeKey).toEqual({ model: "claude-opus-5-5", provider: "anthropic" });
    expect(heroCaption(d)).toMatch(/^latest turn · 30 min ago$/);
    expect(pickerLabel(d)).toBe("Auto · claude-opus-5-5");
  });
  it("falls back to the newest turn with response data, else to the newest turn", () => {
    const noResponse = turn("n", 1, 50, { model: "no-response" });
    expect(buildDashboard(input([noResponse, ...records])).activeKey?.model).toBe("claude-opus-5-5");
    const only = buildDashboard(input([noResponse]));
    expect(only.activeKey?.model).toBe("no-response");
    expect(only.hero.value).toBeNull();
    expect(heroCaption(only)).toBe("Waiting for a response");
  });
  it("restricts Auto to one coding tool and labels it", () => {
    const d = buildDashboard(input(records, { selection: "auto:codex", active: null }));
    expect(d.activeKey?.model).toBe("model-a");
    expect(pickerLabel(d)).toBe("Auto · model-a");
    expect(pickerAccessibleLabel(d)).toBe("Auto in Codex · model-a");
    const live = [liveResponse("c", 1, 80)];
    const claude = buildDashboard(input(records, { selection: "auto:claude-code", live, active: { model: "claude-opus-5-5", provider: "anthropic" } }));
    expect(claude.hero.source).toBe("live");
    expect(pickerLabel(claude)).toBe("Auto · claude-opus-5-5");
    expect(pickerAccessibleLabel(claude)).toBe("Auto in Claude Code · claude-opus-5-5");
  });
  it("pins a model across tools and a cohort exactly", () => {
    const pinned = buildDashboard(input(records, { selection: 'model:["model-a","openai"]' }));
    expect(pinned.activeKey?.model).toBe("model-a");
    expect(pinned.liveDriven).toBe(false);
    expect(pickerLabel(pinned)).toBe("model-a");
    const exact = buildDashboard(input(records, { selection: cohort(claudeTurn("q", 1, 1)) }));
    expect(exact.mode.kind).toBe("cohort");
    expect(exact.selected.map((m) => m.id)).toEqual(["c1", "c2", "c3"]);
    expect(pickerLabel(exact)).toMatch("claude-opus-5-5");
  });
  it("migrates the legacy latest selection to Auto", () => {
    expect(buildDashboard(input(records, { selection: "latest" })).selection).toBe("auto");
  });
});

describe("chart metric", () => {
  const grok = (id: string, minutesAgo: number) =>
    turn(id, minutesAgo, 60, { model: "grok-code-fast-1", provider: "xai", client: "grok-build" });
  const GROK_TEXT =
    "No response speed for these Grok Build turns: they were recorded before Tokrate 0.1.15.";
  it("follows the data until the user picks a metric", () => {
    const timed = buildDashboard(input([claudeTurn("c1", 30, 100)]));
    expect(chartCopy(timed, null).metric).toBe("response");
    expect(chartCopy(timed, "throughput").metric).toBe("throughput");
    const untimed = buildDashboard(input([grok("g1", 10), grok("g2", 20)]));
    expect(chartCopy(untimed, null)).toMatchObject({ metric: "throughput", title: "Turn speed" });
  });
  it("keeps an explicit Response choice and explains why it is empty", () => {
    const d = buildDashboard(input([grok("g1", 10), grok("g2", 20)]));
    const copy = chartCopy(d, "response");
    expect(copy.metric).toBe("response");
    expect(copy.empty).toBe(GROK_TEXT);
    expect(copy.summary.count).toBe(0);
    // Other sources without response timing get the generic text.
    const other = buildDashboard(input([turn("t1", 10, 60)]));
    expect(chartCopy(other, "response").empty).toBe("No response speed for this model yet.");
    expect(chartCopy(other, "throughput").empty).toBe("Collecting data");
  });
  it("falls back to automatic when first token is not captured", () => {
    expect(chartCopy(buildDashboard(input([grok("g1", 10)])), "ttft").metric).toBe("throughput");
    expect(chartCopy(buildDashboard(input([claudeTurn("c1", 30, 100)])), "ttft").metric).toBe("response");
  });
});

describe("Grok Build response speed", () => {
  const grokV2 = (id: string, minutesAgo: number) =>
    turn(id, minutesAgo, 20, {
      model: "grok-4",
      provider: "xai",
      client: "grok-build",
      parserVersion: "grok-session-v2",
      metricVersion: "grok-observed-work-turn-v1",
      codexTTFTSeconds: null,
      outputTokens: 1800,
      durationSeconds: 90,
      responseOutputTokens: 1800,
      responseDurationSeconds: 20,
      responseCount: 9,
    });
  it("drives the hero from the latest turn and flags it as a whole-turn average", () => {
    const d = buildDashboard(input([grokV2("g1", 10), grokV2("g2", 30)]));
    expect(d.hero.source).toBe("turn");
    expect(d.hero.value).toBeCloseTo(90, 6);
    expect(d.heroTurn?.id).toBe("g1");
    expect(isGrokBuild(d.heroTurn)).toBe(true);
    // Other tools' latest turns carry no Grok note.
    const claude = buildDashboard(input([claudeTurn("c", 5, 100)]));
    expect(claude.heroTurn?.id).toBe("c");
    expect(isGrokBuild(claude.heroTurn)).toBe(false);
  });
  it("ranks Grok Build by its per-turn response speed like any other model", () => {
    const row = buildDashboard(input([grokV2("g1", 10), grokV2("g2", 30)])).modelRows[0];
    expect(row.median).toBeCloseTo(90, 6);
    expect(row.turns).toBe(2);
    expect(row.responses).toBe(18);
    expect(row.untimed).toBe(0);
    expect(row.tools).toEqual(["grok-build"]);
  });
  it("uses the exact short note and explanation", () => {
    expect(GROK_RESPONSE_NOTE).toBe("Grok Build: average over all model calls in a turn");
    expect(GROK_RESPONSE_EXPLANATION).toBe(
      "Grok Build records output tokens per turn, not per response, so its response speed is the turn's output tokens divided by the time its model calls spent generating (tool runs and permission waits excluded). Short calls are included, which can make it read lower than per-response measurements from Codex and Claude Code. Turns with nested agents are not counted.",
    );
  });
});

describe("response speed model rows", () => {
  const records = [
    claudeTurn("c1", 30, 120),
    claudeTurn("c2", 60, 100),
    claudeTurn("sub", 45, 200, { sourceKind: "subagent", metricVersion: "claude-observed-subagent-turn-v1", model: "claude-opus-5-5" }),
    rturn("x1", 40, 60),
    rturn("x2", 70, 80),
    // Same model name through another provider route is a separate row.
    claudeTurn("b1", 50, 90, { provider: "amazon-bedrock", providerRegion: "eu" }),
    // Grok reports no per-response timing.
    turn("g1", 20, 30, { client: "grok-build", model: "grok-4", provider: "xai", metricVersion: "grok-observed-work-turn-v1", codexTTFTSeconds: null }),
  ];
  it("groups by model and provider across tools and subagent work, ranked by 24 h median", () => {
    const d = buildDashboard(input(records));
    const rows = d.modelRows.slice().sort((a, b) => (b.median ?? -1) - (a.median ?? -1));
    const claude = rows.find((r) => r.model.model === "claude-opus-5-5" && r.model.provider === "anthropic")!;
    expect(claude.turns).toBe(3);
    expect(claude.median).toBeCloseTo(120, 6);
    expect(claude.hasSubagent).toBe(true);
    expect(claude.responses).toBe(9);
    expect(rows.find((r) => r.model.provider === "amazon-bedrock")?.median).toBeCloseTo(90, 6);
    const codex = rows.find((r) => r.model.model === "model-a")!;
    expect(codex.tools).toEqual(["codex"]);
    expect(codex.median).toBeCloseTo(70, 6);
    const grok = rows.find((r) => r.model.model === "grok-4")!;
    expect(grok.median).toBeNull();
    expect(grok.untimed).toBe(1);
    expect(rows[rows.length - 1]).toBe(grok);
    expect(rows[0]).toBe(claude);
  });
  it("lists tools of a model that runs in several coding tools", () => {
    const shared = [rturn("a", 10, 50, { model: "shared", provider: "openai" }), claudeTurn("b", 20, 70, { model: "shared", provider: "openai" })];
    const row = buildDashboard(input(shared)).modelRows[0];
    expect(row.tools).toEqual(["codex", "claude-code"]);
    expect(row.turns).toBe(2);
  });
  it("keeps the turn-speed measurement groups available", () => {
    const d = buildDashboard(input(records, { sort: "throughput" }));
    expect(d.compareGroups.map((g) => g.title)).toContain("Claude Code · Subagent turn speed");
  });
  it("scales the response gauge by the largest model median", () => {
    const d = buildDashboard(input(records));
    expect(d.gaugeMax).toBe(niceScaleMax(120));
  });
});

describe("efficiency indicator", () => {
  const eff = (id: string, minutesAgo: number, tokens: number, p: Partial<Metric> = {}) =>
    turn(id, minutesAgo, 50, {
      sourceKind: "primary",
      client: "codex",
      outputTokens: tokens,
      delegatedOutputTokens: 0,
      ...p,
    });
  const batch = (model: string, tokens: number, count: number, p: Partial<Metric> = {}) =>
    Array.from({ length: count }, (_, i) => eff(`${model}${i}`, 5 + i * 20, tokens, { model, ...p }));
  // Newest turn belongs to model-a, which spends twice the tokens of the median.
  const records = [...batch("model-a", 2000, 20), ...batch("model-b", 1000, 20), ...batch("model-c", 500, 20)];

  it("scores every model against the whole 7-day history and keeps response speed as the hero", () => {
    const d = buildDashboard(input(records));
    expect(d.efficiency.reference?.median).toBe(1000);
    expect(d.efficiency.rows.map((r) => [r.model, r.indicator]).sort()).toEqual([
      ["model-a", 50],
      ["model-b", 100],
      ["model-c", 200],
    ]);
    expect(d.efficiency.selected?.model).toBe("model-a");
    expect(d.hero.source).toBeNull();
  });
  it("does not change with the 24 h / 7 d range or the selected model", () => {
    const day = buildDashboard(input(records, { days: 1 }));
    const week = buildDashboard(input(records, { days: 7 }));
    expect(day.efficiency.rows).toEqual(week.efficiency.rows);
    const pinned = buildDashboard(input(records, { selection: "model:" + JSON.stringify(["model-c", "openai"]) }));
    expect(pinned.efficiency.selected?.indicator).toBe(200);
    expect(pinned.efficiency.reference?.median).toBe(1000);
  });
  it("applies the coding-tool filter to the population", () => {
    const mixed = [...records, ...batch("claude-x", 4000, 20, { client: "claude-code", provider: "anthropic" })];
    expect(buildDashboard(input(mixed, { tool: "codex" })).efficiency.rows).toHaveLength(3);
    expect(buildDashboard(input(mixed)).efficiency.rows).toHaveLength(4);
  });
  it("excludes subagent records, turns without a final delegated value and trivial turns", () => {
    const noise = [
      eff("sub", 3, 5000, { sourceKind: "subagent", delegatedOutputTokens: null }),
      eff("pending", 4, 5000, { delegatedOutputTokens: null }),
      eff("tiny", 6, 150),
    ];
    const d = buildDashboard(input([...records, ...noise]));
    expect(d.efficiency.reference?.turns).toBe(60);
  });
  it("shows progress instead of a value below 20 requests and says so when nothing qualifies", () => {
    const d = buildDashboard(input(batch("model-a", 1000, 12)));
    expect(d.efficiency.rows[0]).toMatchObject({ turns: 12, indicator: null });
    expect(d.efficiency.reference).toBeNull();
    const copy = chartCopy(d, "efficiency");
    expect(copy.empty).toBe(EFFICIENCY_INSUFFICIENT);
    expect(copy.summary).toMatchObject({ median: null, count: 12 });
  });
  it("offers Efficiency as a chart metric with an unlabelled unit and whole-number values", () => {
    const d = buildDashboard(input(records));
    expect(chartCopy(d, "efficiency")).toMatchObject({
      metric: "efficiency",
      title: "Efficiency indicator",
      unit: "",
      digits: 0,
      noun: "request",
      summary: { median: 50, count: 20 },
    });
    expect(chartCopy(d, "response").digits).toBe(1);
  });
  it("charts tokens per request for all models", () => {
    const d = buildDashboard(input(records, { selection: "all", days: 7 }));
    expect(d.efficiency.unit).toBe("tokens/request");
    expect(chartCopy(d, "efficiency").unit).toBe("tokens/request");
    expect(d.efficiency.buckets.some((b) => b.value === 1000)).toBe(true);
  });
  it("explains the indicator with the exact local copy", () => {
    expect(EFFICIENCY_EXPLANATION).toBe(
      "The efficiency indicator compares the median output tokens a model spends to finish one of your requests (reasoning and delegated subagent work included) with the median across all your requests in the last 7 days. 100 is typical; 200 means half the tokens. It is an indicator, not a benchmark: it depends on what you ask each model to do, requests under 200 tokens are left out, and answer quality is not measured.",
    );
    expect(EFFICIENCY_INSUFFICIENT).toBe(
      "Not enough requests yet: the efficiency indicator needs 20 eligible requests per model.",
    );
  });
});

describe("sharing notice", () => {
  it("shows delegated output tokens in the example payload and the notice", () => {
    const sample = JSON.parse(buildSentExample()).samples[0];
    expect(sample).toHaveProperty("delegatedOutputTokens");
    expect(sample).toHaveProperty("surface");
    for (const key of ["inputTokens", "cacheReadInputTokens", "cacheWriteInputTokens"]) {
      expect(sample).toHaveProperty(key);
    }
    expect(sample.cacheWriteInputTokens).toBeNull();
    expect(DELEGATED_NOTICE).toBe(
      "From 0.1.16 each turn also includes the output tokens of subagent work it started (delegated output tokens), used for the efficiency indicator.",
    );
  });
  it("states the prompt-cache token counts in the notice", () => {
    expect(PROMPT_CACHE_NOTICE).toBe(
      "From 0.1.18 each turn also includes its input token count and how many of those tokens were read from or written to the provider's prompt cache.",
    );
  });
  it("states the surface category in the notice", () => {
    expect(SURFACE_NOTICE).toBe(
      "From 0.1.18 each turn also includes where the coding tool ran, as a category (command line, desktop app, editor extension, SDK or automation, other), never the app's own name.",
    );
  });
});
