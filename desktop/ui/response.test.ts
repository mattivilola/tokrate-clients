import { describe, expect, it } from "vitest";
import { responseSpeed, summarize, type LiveResponse, type Metric } from "./metrics";
import {
  autoSelection,
  BADGE_LABEL,
  BADGE_LETTER,
  badgeFamily,
  fallbackModel,
  liveValue,
  modelSelection,
  parseSelection,
  sortModelRows,
  modelSpeedRows,
} from "./response";
import { previewLive, previewRecords } from "./store/preview";

const NOW = Date.parse("2026-10-04T12:00:00Z");
const live = (id: string, minutesAgo: number, tps: number, p: Partial<LiveResponse> = {}): LiveResponse => ({
  id,
  completedAt: new Date(NOW - minutesAgo * 60000).toISOString(),
  model: "m",
  provider: "anthropic",
  client: "claude-code",
  sourceKind: "primary",
  metricVersion: "response-v1",
  reasoningEffort: null,
  outputTokens: 400,
  durationSeconds: 400 / tps,
  ...p,
});

describe("response speed helpers", () => {
  it("reads response speed only from consistent response fields", () => {
    const base = { id: "x", completedAt: "2026-10-04T12:00:00Z", model: "m", outputTokens: 1, durationSeconds: 1, codexTTFTSeconds: null, turnThroughputTPS: 1 } as Metric;
    expect(responseSpeed({ ...base, responseOutputTokens: 600, responseDurationSeconds: 5 })).toBe(120);
    expect(responseSpeed({ ...base, responseOutputTokens: null, responseDurationSeconds: null })).toBeNull();
    expect(responseSpeed({ ...base, responseOutputTokens: 600, responseDurationSeconds: 0 })).toBeNull();
    expect(responseSpeed(base)).toBeNull();
    expect(
      summarize([
        { ...base, responseOutputTokens: 600, responseDurationSeconds: 5 },
        { ...base, responseOutputTokens: 300, responseDurationSeconds: 5 },
        base,
      ]).response,
    ).toMatchObject({ median: 90, count: 2 });
  });

  it("takes the median of the newest five live responses within ten minutes", () => {
    const scope = { model: "m", provider: "anthropic", client: null };
    const stream = [live("a", 9, 10), live("b", 6, 20), live("c", 5, 30), live("d", 4, 40), live("e", 3, 50), live("f", 2, 60)];
    expect(liveValue(stream, scope, NOW)).toMatchObject({ speed: 40, count: 5 });
    expect(liveValue(stream, scope, NOW + 7 * 60000)?.count).toBe(2);
    expect(liveValue(stream, scope, NOW + 13 * 60000)).toBeNull();
    expect(liveValue(stream, { ...scope, model: "other" }, NOW)).toBeNull();
    expect(liveValue(stream, { ...scope, client: "codex" }, NOW)).toBeNull();
    expect(liveValue([live("x", 1, 10), live("y", 1, 30)], scope, NOW)?.speed).toBe(20);
    // Unknown and missing providers are the same route.
    expect(liveValue([live("z", 1, 25, { provider: null })], { ...scope, provider: "unknown" }, NOW)?.speed).toBe(25);
  });

  it("parses every selection form and treats latest as auto", () => {
    expect(parseSelection("auto")).toEqual({ kind: "auto", tool: null });
    expect(parseSelection("latest")).toEqual({ kind: "auto", tool: null });
    expect(parseSelection("auto:codex")).toEqual({ kind: "auto", tool: "codex" });
    expect(parseSelection("auto:nope")).toEqual({ kind: "auto", tool: null });
    expect(parseSelection("all")).toEqual({ kind: "all" });
    expect(parseSelection(modelSelection({ model: "gpt-5", provider: "openai" }))).toEqual({ kind: "model", key: { model: "gpt-5", provider: "openai" } });
    const cohort = JSON.stringify(["codex", null, "p", "m", "gpt", "openai", null, "high", "primary"]);
    expect(parseSelection(cohort)).toMatchObject({ kind: "cohort", client: "codex", model: "gpt", provider: "openai" });
    // The pre-0.1.14 eight-part identity is no longer a cohort.
    expect(parseSelection(JSON.stringify(["codex", null, "p", "m", "gpt", "openai", "high", "primary"]))).toEqual({ kind: "auto", tool: null });
    expect(autoSelection("claude-code")).toBe("auto:claude-code");
    expect(autoSelection(null)).toBe("auto");
  });

  it("selects Antigravity as a coding tool", () => {
    expect(parseSelection("auto:antigravity")).toEqual({ kind: "auto", tool: "antigravity" });
    expect(autoSelection("antigravity")).toBe("auto:antigravity");
    expect(parseSelection("auto:opencode")).toEqual({ kind: "auto", tool: "opencode" });
    expect(autoSelection("opencode")).toBe("auto:opencode");
  });

  it("classifies the provider badge like the native tray icon", () => {
    expect(badgeFamily("claude-opus-5-5", null)).toBe("anthropic");
    expect(badgeFamily("claude-sonnet-4-5", "amazon-bedrock")).toBe("anthropic");
    expect(badgeFamily(null, "anthropic")).toBe("anthropic");
    expect(badgeFamily("gpt-5-codex", "unknown")).toBe("openai");
    expect(badgeFamily("o3", null)).toBe("openai");
    expect(badgeFamily("omega", null)).toBe("unknown");
    expect(badgeFamily("x", "openai")).toBe("openai");
    expect(badgeFamily("grok-4", null)).toBe("xai");
    expect(badgeFamily("anything", "xai")).toBe("xai");
    expect(badgeFamily("gemini-3.8-flash", null)).toBe("google");
    expect(badgeFamily("Gemini-3.8-pro", "unknown")).toBe("google");
    expect(badgeFamily("anything", "google")).toBe("google");
    expect(badgeFamily("claude-opus-4-6-thinking", "unknown")).toBe("anthropic");
    expect(BADGE_LETTER.google).toBe("G");
    expect(BADGE_LABEL.google).toBe("Google");
    expect(badgeFamily("mystery", "amazon-bedrock")).toBe("unknown");
    expect(badgeFamily(null, null)).toBe("unknown");
  });

  it("falls back to the newest turn with response data", () => {
    const base = { id: "x", completedAt: "2026-10-04T12:00:00Z", outputTokens: 1, durationSeconds: 1, codexTTFTSeconds: null, turnThroughputTPS: 1 };
    const records: Metric[] = [
      { ...base, model: "newest" },
      { ...base, model: "timed", provider: "openai", responseOutputTokens: 300, responseDurationSeconds: 3, responseCount: 1 },
    ];
    expect(fallbackModel(records)).toEqual({ model: "timed", provider: "openai" });
    expect(fallbackModel([records[0]])).toEqual({ model: "newest", provider: "unknown" });
    expect(fallbackModel([])).toBeNull();
  });

  it("sorts model rows by speed or recency", () => {
    const records = previewRecords(NOW);
    const rows = modelSpeedRows(records, NOW - 86400000, NOW + 1);
    const speed = sortModelRows(rows, "speed");
    expect(speed.map((r) => r.median ?? -1)).toEqual([...speed.map((r) => r.median ?? -1)].sort((a, b) => b - a));
    const recent = sortModelRows(rows, "recent");
    expect(recent.map((r) => r.latestAt)).toEqual([...recent.map((r) => r.latestAt)].sort((a, b) => b - a));
  });

  it("gives the dev preview response fields and a live stream", () => {
    const records = previewRecords(NOW);
    expect(records.every((m) => (m.responseOutputTokens ?? 0) <= m.outputTokens)).toBe(true);
    expect(records.every((m) => responseSpeed(m) !== null)).toBe(true);
    expect(previewLive(NOW).length).toBeGreaterThanOrEqual(5);
  });
});
