import { describe, expect, it } from "vitest";
import type { ProviderErrorGroup } from "../store/types";
import { providerErrorLine } from "./provider-errors";

const NOW = Date.parse("2026-10-13T12:00:00Z");
const MIN = 60_000;
const HOUR = 60 * MIN;

const group = (over: Partial<ProviderErrorGroup> & { agoMs?: number } = {}): ProviderErrorGroup => {
  const { agoMs = 5 * MIN, ...rest } = over;
  return {
    client: "claude-code",
    model: "claude-opus-5-5",
    kind: "overloaded",
    count: 2,
    latestAt: new Date(NOW - agoMs).toISOString(),
    ...rest,
  };
};

describe("providerErrorLine", () => {
  it("is hidden without groups", () => {
    expect(providerErrorLine(undefined, NOW)).toBeNull();
    expect(providerErrorLine([], NOW)).toBeNull();
  });

  it("is hidden once the latest failure is older than 24 hours", () => {
    expect(providerErrorLine([group({ agoMs: 24 * HOUR + MIN })], NOW)).toBeNull();
    expect(providerErrorLine([group({ agoMs: 23 * HOUR })], NOW)).not.toBeNull();
    // Only a stale group among fresh ones is left out.
    const line = providerErrorLine(
      [group({ model: "fresh" }), group({ model: "stale", agoMs: 30 * HOUR })],
      NOW,
    );
    expect(line).toContain("on fresh");
    expect(line).not.toContain("Also");
  });

  it("ignores a group whose time cannot be read", () => {
    expect(providerErrorLine([group({ latestAt: "not a time" })], NOW)).toBeNull();
  });

  it("words an overload of Codex as model at capacity", () => {
    expect(
      providerErrorLine([group({ client: "codex", model: "gpt-5.5", count: 3, agoMs: 2 * HOUR })], NOW),
    ).toBe(
      "You hit “model at capacity” 3 times on gpt-5.5 in the last 24 hours, most recently 2 h ago. That’s the provider at capacity, not your connection.",
    );
  });

  it("words an overload of any other tool as overloaded", () => {
    for (const client of ["claude-code", "opencode", "kimi-code"]) {
      expect(providerErrorLine([group({ client, count: 2, agoMs: 10 * MIN })], NOW)).toBe(
        "You hit “overloaded” 2 times on claude-opus-5-5 in the last 24 hours, most recently 10 min ago. That’s the provider at capacity, not your connection.",
      );
    }
  });

  it("words a server error for every tool", () => {
    for (const client of ["codex", "claude-code"]) {
      expect(
        providerErrorLine([group({ client, kind: "serverError", count: 4, agoMs: 30 * 1000 })], NOW),
      ).toBe(
        "claude-opus-5-5 returned 4 server errors in the last 24 hours, most recently just now. That’s a failure at the provider, not your connection.",
      );
    }
  });

  it("uses the singular for one failure", () => {
    expect(providerErrorLine([group({ client: "codex", count: 1 })], NOW)).toContain(
      "“model at capacity” 1 time on",
    );
    expect(providerErrorLine([group({ kind: "serverError", count: 1 })], NOW)).toContain(
      "returned 1 server error in",
    );
  });

  it("describes the group with the latest failure, whatever the input order", () => {
    const line = providerErrorLine(
      [group({ model: "older", agoMs: HOUR }), group({ model: "newer", agoMs: MIN })],
      NOW,
    );
    expect(line).toMatch(/on newer in the last 24 hours/);
    expect(line?.endsWith(" Also: older (2)")).toBe(true);
  });

  it("names at most two more groups, most recent first", () => {
    const groups = [
      group({ model: "main", agoMs: MIN }),
      group({ model: "second", agoMs: 2 * MIN, count: 1 }),
      group({ model: "third", agoMs: 3 * MIN, count: 5, kind: "serverError" }),
      group({ model: "fourth", agoMs: 4 * MIN }),
    ];
    const line = providerErrorLine(groups, NOW);
    expect(line?.endsWith("not your connection. Also: second (1), third (5)")).toBe(true);
    expect(line).not.toContain("fourth");
  });

  it("has no Also suffix for a single group", () => {
    expect(providerErrorLine([group()], NOW)).not.toContain("Also");
  });
});
