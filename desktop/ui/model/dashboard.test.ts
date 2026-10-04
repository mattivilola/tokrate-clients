import { describe, expect, it } from "vitest";
import { DAY, cohort, type Metric } from "../metrics";
import { buildDashboard, communityLine } from "./dashboard";
import { PROVIDER_TITLES, folderName, readout, signedPercent } from "./format";
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
  selection: "latest",
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
    expect(d.selection).toBe("latest");
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
  it("offers every attributable provider in the filter", () => {
    expect(PROVIDER_TITLES).toEqual({
      openai: "OpenAI",
      anthropic: "Anthropic",
      "amazon-bedrock": "Amazon Bedrock",
      "google-vertex": "Google Vertex AI",
      xai: "xAI",
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
    expect(d.gaugeMax).toBe(75);
    const only = buildDashboard(input([sub], { selection: "latest" }));
    expect(only.gaugeMax).toBe(500);
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
