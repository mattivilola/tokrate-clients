import { describe, expect, it } from "vitest";
import type { ErrorRecovery, ProviderErrorGroup, RelevantErrorAlert } from "../store/types";
import {
  advanceRecovery,
  communityErrorLine,
  NO_RECOVERY,
  providerErrorLine,
  RECOVERY_MS,
  SHARING_HINT,
  type CommunityErrorInput,
} from "./provider-errors";

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

  it("words a throttle with the plan percentage when it is known", () => {
    expect(
      providerErrorLine(
        [group({ client: "codex", kind: "throttled", count: 3, planUsedPercent: 42, agoMs: 10 * MIN })],
        NOW,
      ),
    ).toBe(
      "You were rate limited 3 times on claude-opus-5-5 in the last 24 hours while your plan still had quota left (42% used). That’s the provider throttling, not your plan limit.",
    );
    // 0% used is a known percentage.
    expect(
      providerErrorLine([group({ kind: "throttled", count: 1, planUsedPercent: 0 })], NOW),
    ).toBe(
      "You were rate limited 1 time on claude-opus-5-5 in the last 24 hours while your plan still had quota left (0% used). That’s the provider throttling, not your plan limit.",
    );
  });

  it("words a throttle without the percentage when none is known", () => {
    for (const client of ["claude-code", "codex"]) {
      expect(providerErrorLine([group({ client, kind: "throttled", count: 2 })], NOW)).toBe(
        "You were rate limited 2 times on claude-opus-5-5 in the last 24 hours while your plan still had quota left. That’s the provider throttling, not your plan limit.",
      );
    }
  });

  it("lets a throttle be an Also group and the main group when most recent", () => {
    const line = providerErrorLine(
      [group({ model: "a", agoMs: MIN }), group({ model: "b", kind: "throttled", count: 4, agoMs: 2 * MIN })],
      NOW,
    );
    expect(line?.endsWith(" Also: b (4)")).toBe(true);
    expect(
      providerErrorLine(
        [group({ model: "a", agoMs: 2 * MIN }), group({ model: "b", kind: "throttled", agoMs: MIN })],
        NOW,
      ),
    ).toMatch(/^You were rate limited 2 times on b in the last 24 hours/);
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

/** What the native shell selects as relevant: the formatting below only words this list. */
const alert = (over: Partial<RelevantErrorAlert> = {}): RelevantErrorAlert => ({
  model: "claude-opus-5-5",
  failingContributors: 4,
  overloaded: 6,
  serverError: 0,
  throttled: 0,
  lastFailureAt: new Date(NOW - 3 * MIN).toISOString(),
  notJustYou: false,
  others: 3,
  ...over,
});
/** The form for a failure of the user's own in the last hour. */
const own = (over: Partial<RelevantErrorAlert> = {}) => alert({ notJustYou: true, ...over });
const input = (over: Partial<CommunityErrorInput> = {}): CommunityErrorInput => ({
  relevant: [alert()],
  sharing: true,
  now: NOW,
  ...over,
});
const line = (over: Partial<CommunityErrorInput> = {}, recovery: ErrorRecovery = NO_RECOVERY) =>
  communityErrorLine(input(over), recovery)?.text ?? null;

describe("communityErrorLine reporting form", () => {
  it("words overloaded counts, the contributors and the latest failure", () => {
    expect(line()).toBe(
      "Tokrate contributors are reporting provider errors on claude-opus-5-5: 6 overloaded / at capacity from 4 contributors in the last hour, latest 3 min ago.",
    );
  });

  it("words server errors alone, singular and plural", () => {
    expect(line({ relevant: [alert({ overloaded: 0, serverError: 1, failingContributors: 3 })] })).toBe(
      "Tokrate contributors are reporting provider errors on claude-opus-5-5: 1 server error from 3 contributors in the last hour, latest 3 min ago.",
    );
    expect(line({ relevant: [alert({ overloaded: 0, serverError: 5, failingContributors: 3 })] })).toContain(
      ": 5 server errors from",
    );
  });

  it("joins both counts with and", () => {
    expect(line({ relevant: [alert({ overloaded: 2, serverError: 1 })] })).toContain(
      ": 2 overloaded / at capacity and 1 server error from 4 contributors",
    );
    expect(line({ relevant: [alert({ overloaded: 1, serverError: 7 })] })).toContain(
      ": 1 overloaded / at capacity and 7 server errors from",
    );
  });

  it("words throttled counts and joins three counts with commas and a final and", () => {
    expect(line({ relevant: [alert({ overloaded: 0, throttled: 5, failingContributors: 3 })] })).toBe(
      "Tokrate contributors are reporting provider errors on claude-opus-5-5: 5 throttled (not plan limits) from 3 contributors in the last hour, latest 3 min ago.",
    );
    expect(line({ relevant: [alert({ overloaded: 2, throttled: 5 })] })).toContain(
      ": 2 overloaded / at capacity and 5 throttled (not plan limits) from 4 contributors",
    );
    expect(line({ relevant: [alert({ overloaded: 0, serverError: 1, throttled: 2 })] })).toContain(
      ": 1 server error and 2 throttled (not plan limits) from",
    );
    expect(line({ relevant: [alert({ overloaded: 1, serverError: 2, throttled: 3 })] })).toContain(
      ": 1 overloaded / at capacity, 2 server errors and 3 throttled (not plan limits) from 4 contributors",
    );
  });

  it("uses the singular for one contributor", () => {
    expect(line({ relevant: [alert({ failingContributors: 1 })] })).toContain("from 1 contributor in the last hour");
  });

  it("words the latest failure relative to now", () => {
    expect(line({ relevant: [alert({ lastFailureAt: new Date(NOW - 20 * 1000).toISOString() })] })).toContain(
      "latest just now.",
    );
    expect(line({ relevant: [alert({ lastFailureAt: new Date(NOW - 50 * MIN).toISOString() })] })).toContain(
      "latest 50 min ago.",
    );
  });
});

describe("communityErrorLine not just you", () => {
  it("counts the other contributors when the native shell flags a failure of the user's own", () => {
    expect(line({ relevant: [own()] })).toBe(
      "It’s not just you: 3 other contributors hit provider errors on claude-opus-5-5 in the last hour.",
    );
  });

  it("uses the singular for one other contributor", () => {
    expect(line({ relevant: [own({ failingContributors: 2, others: 1 })] })).toBe(
      "It’s not just you: 1 other contributor hit provider errors on claude-opus-5-5 in the last hour.",
    );
  });

  it("words the first alert of the list, whatever its form", () => {
    const text = line({ relevant: [alert({ model: "m-next" }), own({ model: "m-own" })] });
    expect(text).toMatch(/^Tokrate contributors are reporting provider errors on m-next: /);
    expect(text).toMatch(/ Also: m-own$/);
  });
});

describe("communityErrorLine without alerts", () => {
  it("shows nothing without alerts", () => {
    expect(line({ relevant: undefined })).toBeNull();
    expect(line({ relevant: [] })).toBeNull();
  });

  it("shows nothing while sharing is off", () => {
    expect(line({ sharing: false })).toBeNull();
  });
});

describe("communityErrorLine Also", () => {
  const list = (...models: string[]) => models.map((model) => alert({ model }));

  it("names the first alert and at most two more, joined with commas", () => {
    const text = line({ relevant: list("m-a", "m-b", "m-c", "m-d") });
    expect(text).toContain("errors on m-a:");
    expect(text?.endsWith(" Also: m-b, m-c")).toBe(true);
    expect(text).not.toContain("m-d");
  });

  it("names one more alone and none for a single alert", () => {
    expect(line({ relevant: list("m-a", "m-b") })?.endsWith(" Also: m-b")).toBe(true);
    expect(line()).not.toContain("Also");
  });

  it("names a model once when it alerts for several providers", () => {
    const text = line({ relevant: list("m-a", "m-a", "m-b") });
    expect(text?.endsWith(" Also: m-b")).toBe(true);
    expect(line({ relevant: list("m-a", "m-a") })).not.toContain("Also");
  });

  it("applies Also after the not-just-you form too", () => {
    const text = line({ relevant: [own({ model: "m-a" }), alert({ model: "m-b" })] });
    expect(text?.startsWith("It’s not just you:")).toBe(true);
    expect(text?.endsWith(" Also: m-b")).toBe(true);
  });
});

describe("communityErrorLine recovery", () => {
  const recovery = (cleared: { model: string; at: number }[]): ErrorRecovery => ({ shown: [], cleared });

  it("says contributors no longer report errors for 30 minutes", () => {
    const cleared = recovery([{ model: "claude-opus-5-5", at: NOW - 5 * MIN }]);
    expect(line({ relevant: [] }, cleared)).toBe(
      "claude-opus-5-5: contributors no longer report provider errors (cleared 5 min ago).",
    );
    const justBefore = recovery([{ model: "claude-opus-5-5", at: NOW - RECOVERY_MS + 1 }]);
    expect(line({ relevant: [] }, justBefore)).not.toBeNull();
    const expired = recovery([{ model: "claude-opus-5-5", at: NOW - RECOVERY_MS }]);
    expect(line({ relevant: [] }, expired)).toBeNull();
  });

  it("names the model that cleared last", () => {
    const cleared = recovery([
      { model: "older", at: NOW - 20 * MIN },
      { model: "newer", at: NOW - 2 * MIN },
    ]);
    expect(line({ relevant: [] }, cleared)).toMatch(/^newer: /);
  });

  it("gives way to an alert line", () => {
    const cleared = recovery([{ model: "other", at: NOW - MIN }]);
    expect(line({}, cleared)).toContain("Tokrate contributors are reporting");
  });

  it("is not shown while sharing is off", () => {
    expect(line({ sharing: false, relevant: [] }, recovery([{ model: "m", at: NOW - MIN }]))).toBeNull();
  });
});

describe("advanceRecovery", () => {
  /** The board lists `models`; the native shell selected `relevant` of them (default: all). */
  const step = (
    previous: ErrorRecovery,
    models: string[] | null,
    at: number,
    over: Partial<CommunityErrorInput> = {},
  ) =>
    advanceRecovery(
      previous,
      models === null ? null : { errors: { alerts: models.map((model) => boardAlert(model)) } },
      input({ relevant: models ? models.map((model) => alert({ model })) : undefined, now: at, ...over }),
    );
  const boardAlert = (model: string) => ({
    model,
    provider: "anthropic",
    clients: ["claude-code"],
    failingContributors: 4,
    overloaded: 6,
    serverError: 0,
    throttled: 0,
    firstFailureAt: new Date(NOW - 40 * MIN).toISOString(),
    lastFailureAt: new Date(NOW - 3 * MIN).toISOString(),
  });

  it("remembers a shown alert and clears it when it disappears", () => {
    let state = step(NO_RECOVERY, ["claude-opus-5-5"], NOW);
    expect(state).toEqual({ shown: ["claude-opus-5-5"], cleared: [] });
    state = step(state, ["claude-opus-5-5"], NOW + MIN);
    expect(state.cleared).toEqual([]);
    state = step(state, [], NOW + 2 * MIN);
    expect(state).toEqual({ shown: [], cleared: [{ model: "claude-opus-5-5", at: NOW + 2 * MIN }] });
  });

  it("returns the same state when nothing changed", () => {
    const state = step(NO_RECOVERY, ["claude-opus-5-5"], NOW);
    expect(step(state, ["claude-opus-5-5"], NOW + MIN)).toBe(state);
    expect(step(NO_RECOVERY, [], NOW)).toBe(NO_RECOVERY);
  });

  it("only follows alerts that were shown", () => {
    // On the board but not selected for the user (unused model, or only their own report): never
    // shown, so nothing to recover from.
    const state = step(NO_RECOVERY, ["claude-opus-5-5"], NOW, { relevant: [] });
    expect(state).toBe(NO_RECOVERY);
    expect(step(state, [], NOW + MIN)).toBe(NO_RECOVERY);
  });

  it("follows the models named by Also as well", () => {
    let state = step(NO_RECOVERY, ["m-a", "m-b"], NOW);
    expect(state.shown).toEqual(["m-a", "m-b"]);
    state = step(state, ["m-a"], NOW + MIN);
    expect(state.cleared).toEqual([{ model: "m-b", at: NOW + MIN }]);
  });

  it("drops a recovery when the model alerts again, and after 30 minutes", () => {
    let state = step(NO_RECOVERY, ["claude-opus-5-5"], NOW);
    state = step(state, [], NOW + MIN);
    state = step(state, ["claude-opus-5-5"], NOW + 2 * MIN);
    expect(state).toEqual({ shown: ["claude-opus-5-5"], cleared: [] });
    state = step(state, [], NOW + 3 * MIN);
    expect(state.cleared).toHaveLength(1);
    state = step(state, [], NOW + 3 * MIN + RECOVERY_MS);
    expect(state).toEqual({ shown: [], cleared: [] });
  });

  it("learns nothing from a poll without a board and forgets everything when sharing is off", () => {
    const shown = step(NO_RECOVERY, ["claude-opus-5-5"], NOW);
    expect(step(shown, null, NOW + MIN)).toBe(shown);
    const cleared = step(shown, [], NOW + MIN);
    expect(step(cleared, null, NOW + 2 * MIN, { sharing: false })).toBe(NO_RECOVERY);
    expect(step(NO_RECOVERY, null, NOW, { sharing: false })).toBe(NO_RECOVERY);
  });
});

describe("sharing hint", () => {
  it("is the contract's wording", () => {
    expect(SHARING_HINT).toBe("Turn on sharing to see whether other contributors hit the same errors.");
  });
});
