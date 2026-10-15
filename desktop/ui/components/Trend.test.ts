import { describe, expect, it } from "vitest";
import type { Metric } from "../metrics";
import { supportsFirstToken } from "./Trend";

const sample = (client: string, parserVersion?: string, metricVersion?: string): Metric => ({
  id: "sample",
  completedAt: "2026-10-15T00:00:00.000Z",
  model: "example-model",
  client,
  parserVersion,
  metricVersion,
  outputTokens: 300,
  durationSeconds: 10,
  codexTTFTSeconds: null,
  turnThroughputTPS: 30,
});

describe("first-token availability", () => {
  it("uses the T3 runtime parser and metric rather than excluding the T3 tool id", () => {
    expect(supportsFirstToken(sample("codex", "codex-rollout-v2", "turn-v1"))).toBe(true);
    expect(supportsFirstToken(sample("t3-code", "codex-rollout-v2", "turn-v1"))).toBe(true);
    expect(supportsFirstToken(sample("t3-code", "claude-transcript-v4", "claude-observed-turn-v1"))).toBe(false);
    expect(supportsFirstToken(sample("t3-code", "claude-transcript-v4", "claude-observed-subagent-turn-v1"))).toBe(false);
    expect(supportsFirstToken(sample("t3-code", "antigravity-conversation-v1", "antigravity-observed-execution-v1"))).toBe(false);
  });
});
