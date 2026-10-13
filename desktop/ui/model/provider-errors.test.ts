import { describe, expect, it } from "vitest";
import type { CommunityErrorAlert, ErrorRecovery, ProviderErrorGroup } from "../store/types";
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

const alert = (over: Partial<CommunityErrorAlert> = {}): CommunityErrorAlert => ({
  model: "claude-opus-5-5",
  provider: "anthropic",
  clients: ["claude-code"],
  failingContributors: 4,
  overloaded: 6,
  serverError: 0,
  firstFailureAt: new Date(NOW - 40 * MIN).toISOString(),
  lastFailureAt: new Date(NOW - 3 * MIN).toISOString(),
  ...over,
});
/** A turn of `model` completed `agoMs` ago. */
const turn = (model: string | null, agoMs = HOUR) => ({
  model,
  completedAt: new Date(NOW - agoMs).toISOString(),
});
const input = (over: Partial<CommunityErrorInput> = {}): CommunityErrorInput => ({
  alerts: [alert()],
  sharing: true,
  records: [turn("claude-opus-5-5")],
  groups: [],
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
    expect(line({ alerts: [alert({ overloaded: 0, serverError: 1, failingContributors: 3 })] })).toBe(
      "Tokrate contributors are reporting provider errors on claude-opus-5-5: 1 server error from 3 contributors in the last hour, latest 3 min ago.",
    );
    expect(line({ alerts: [alert({ overloaded: 0, serverError: 5, failingContributors: 3 })] })).toContain(
      ": 5 server errors from",
    );
  });

  it("joins both counts with and", () => {
    expect(line({ alerts: [alert({ overloaded: 2, serverError: 1 })] })).toContain(
      ": 2 overloaded / at capacity and 1 server error from 4 contributors",
    );
    expect(line({ alerts: [alert({ overloaded: 1, serverError: 7 })] })).toContain(
      ": 1 overloaded / at capacity and 7 server errors from",
    );
  });

  it("uses the singular for one contributor", () => {
    expect(line({ alerts: [alert({ failingContributors: 1 })] })).toContain("from 1 contributor in the last hour");
  });

  it("words the latest failure relative to now", () => {
    expect(line({ alerts: [alert({ lastFailureAt: new Date(NOW - 20 * 1000).toISOString() })] })).toContain(
      "latest just now.",
    );
    expect(line({ alerts: [alert({ lastFailureAt: new Date(NOW - 50 * MIN).toISOString() })] })).toContain(
      "latest 50 min ago.",
    );
  });
});

describe("communityErrorLine not just you", () => {
  const failedLastHour = [group({ agoMs: 20 * MIN })];

  it("counts the other contributors when the user failed on the model in the last hour", () => {
    expect(line({ groups: failedLastHour })).toBe(
      "It’s not just you: 3 other contributors hit provider errors on claude-opus-5-5 in the last hour.",
    );
  });

  it("uses the singular for one other contributor", () => {
    expect(line({ groups: failedLastHour, alerts: [alert({ failingContributors: 2 })] })).toBe(
      "It’s not just you: 1 other contributor hit provider errors on claude-opus-5-5 in the last hour.",
    );
  });

  it("skips the alert when nobody else is counted and uses the next relevant one", () => {
    const alerts = [alert({ failingContributors: 1 }), alert({ model: "m-next" })];
    const records = [turn("claude-opus-5-5"), turn("m-next")];
    const text = line({ groups: failedLastHour, alerts, records });
    expect(text).toBe(
      "Tokrate contributors are reporting provider errors on m-next: 6 overloaded / at capacity from 4 contributors in the last hour, latest 3 min ago.",
    );
    // The skipped model is not named in Also either.
    expect(line({ groups: failedLastHour, alerts: [...alerts, alert({ model: "m-last" })], records: [...records, turn("m-last")] }))
      .toMatch(/ Also: m-last$/);
  });

  it("shows nothing when the only alert is the user's own report", () => {
    expect(line({ groups: failedLastHour, alerts: [alert({ failingContributors: 1 })] })).toBeNull();
    expect(communityErrorLine(input({ groups: failedLastHour, alerts: [alert({ failingContributors: 1 })] }), NO_RECOVERY)).toBeNull();
  });

  it("still reports an own-failure alert in the reporting form when the failure is older than an hour", () => {
    expect(line({ groups: [group({ agoMs: 3 * HOUR })], alerts: [alert({ failingContributors: 1 })] })).toContain(
      "from 1 contributor in the last hour",
    );
  });

  it("needs a failure within the last hour, not just the last 24", () => {
    expect(line({ groups: [group({ agoMs: 3 * HOUR })] })).toContain("Tokrate contributors are reporting");
  });

  it("matches the exact model id", () => {
    expect(line({ groups: [group({ model: "claude-opus-5-5-other", agoMs: MIN })] })).toContain(
      "Tokrate contributors are reporting",
    );
  });

  it("takes the failure of any tool or kind on the model", () => {
    for (const over of [{ client: "codex" }, { kind: "serverError" as const }]) {
      expect(line({ groups: [group({ ...over, agoMs: 10 * MIN })] })).toContain("It’s not just you: 3 other");
    }
  });
});

describe("communityErrorLine relevance", () => {
  it("shows nothing without alerts", () => {
    expect(line({ alerts: undefined })).toBeNull();
    expect(line({ alerts: [] })).toBeNull();
  });

  it("shows nothing while sharing is off", () => {
    expect(line({ sharing: false })).toBeNull();
  });

  it("needs the model to be used in the last 7 days or to have failed locally in 24 hours", () => {
    expect(line({ records: [] })).toBeNull();
    expect(line({ records: [turn("something-else")] })).toBeNull();
    expect(line({ records: [turn("claude-opus-5-5-other")] })).toBeNull();
    expect(line({ records: [turn(null)] })).toBeNull();
    expect(line({ records: [turn("claude-opus-5-5", 6 * 24 * HOUR)] })).not.toBeNull();
    expect(line({ records: [turn("claude-opus-5-5", 8 * 24 * HOUR)] })).toBeNull();
    expect(line({ records: [turn("claude-opus-5-5", -HOUR)] })).not.toBeNull();
    expect(line({ records: [], groups: [group({ agoMs: 23 * HOUR })] })).not.toBeNull();
    expect(line({ records: [], groups: [group({ agoMs: 25 * HOUR })] })).toBeNull();
  });

  it("leaves out alerts that do not fit the shape", () => {
    const broken = [
      null,
      "text",
      { model: "claude-opus-5-5" },
      alert({ model: "" }),
      alert({ failingContributors: "3" as never }),
      alert({ overloaded: -1 }),
    ] as never[];
    expect(line({ alerts: broken })).toBeNull();
    expect(line({ alerts: [...broken, alert({ model: "claude-opus-5-5", failingContributors: 2 })] })).toContain(
      "from 2 contributors",
    );
  });

  it("reads at most 20 alerts", () => {
    const filler = Array.from({ length: 20 }, (_, i) => alert({ model: `other-${i}` }));
    expect(line({ alerts: [...filler, alert()] })).toBeNull();
    expect(line({ alerts: [...filler.slice(1), alert()] })).not.toBeNull();
  });
});

describe("communityErrorLine ordering and Also", () => {
  const models = ["m-a", "m-b", "m-c", "m-d"];
  const used = models.map((model) => turn(model));

  it("follows the server's order without a failure in the last hour", () => {
    const alerts = models.map((model) => alert({ model }));
    expect(line({ alerts, records: used })).toContain("errors on m-a:");
  });

  it("puts a model with a failure in the last hour first", () => {
    const alerts = models.map((model) => alert({ model }));
    const text = line({ alerts, records: used, groups: [group({ model: "m-c", agoMs: 5 * MIN })] });
    expect(text).toContain("It’s not just you: 3 other contributors hit provider errors on m-c in the last hour.");
    expect(text?.endsWith("Also: m-a, m-b")).toBe(true);
  });

  it("keeps the server's order among several with a failure in the last hour", () => {
    const alerts = models.map((model) => alert({ model }));
    const groups = [group({ model: "m-d", agoMs: MIN }), group({ model: "m-b", agoMs: 30 * MIN })];
    const text = line({ alerts, records: used, groups });
    expect(text).toContain("on m-b in the last hour.");
    expect(text?.endsWith("Also: m-d, m-a")).toBe(true);
  });

  it("names at most two more, joined with commas, only relevant ones", () => {
    const alerts = ["m-a", "unused", "m-b", "m-c", "m-d"].map((model) => alert({ model }));
    const text = line({ alerts, records: used });
    expect(text?.endsWith(" Also: m-b, m-c")).toBe(true);
    expect(text).not.toContain("unused");
    expect(text).not.toContain("m-d");
  });

  it("names one more alone and none for a single alert", () => {
    const two = line({ alerts: [alert({ model: "m-a" }), alert({ model: "m-b" })], records: used });
    expect(two?.endsWith(" Also: m-b")).toBe(true);
    expect(line()).not.toContain("Also");
  });

  it("names a model once when it alerts for several providers", () => {
    const text = line({
      alerts: [alert({ model: "m-a" }), alert({ model: "m-a", provider: "other" }), alert({ model: "m-b" })],
      records: used,
    });
    expect(text?.endsWith(" Also: m-b")).toBe(true);
  });

  it("applies Also after the not-just-you form too", () => {
    const text = line({
      alerts: [alert({ model: "m-a" }), alert({ model: "m-b" })],
      records: used,
      groups: [group({ model: "m-a", agoMs: MIN })],
    });
    expect(text?.startsWith("It’s not just you:")).toBe(true);
    expect(text?.endsWith(" Also: m-b")).toBe(true);
  });
});

describe("communityErrorLine recovery", () => {
  const recovery = (cleared: { model: string; at: number }[]): ErrorRecovery => ({ shown: [], cleared });

  it("says contributors no longer report errors for 30 minutes", () => {
    const cleared = recovery([{ model: "claude-opus-5-5", at: NOW - 5 * MIN }]);
    expect(line({ alerts: [] }, cleared)).toBe(
      "claude-opus-5-5: contributors no longer report provider errors (cleared 5 min ago).",
    );
    const justBefore = recovery([{ model: "claude-opus-5-5", at: NOW - RECOVERY_MS + 1 }]);
    expect(line({ alerts: [] }, justBefore)).not.toBeNull();
    const expired = recovery([{ model: "claude-opus-5-5", at: NOW - RECOVERY_MS }]);
    expect(line({ alerts: [] }, expired)).toBeNull();
  });

  it("names the model that cleared last", () => {
    const cleared = recovery([
      { model: "older", at: NOW - 20 * MIN },
      { model: "newer", at: NOW - 2 * MIN },
    ]);
    expect(line({ alerts: [] }, cleared)).toMatch(/^newer: /);
  });

  it("gives way to an alert line", () => {
    const cleared = recovery([{ model: "other", at: NOW - MIN }]);
    expect(line({}, cleared)).toContain("Tokrate contributors are reporting");
  });

  it("is not shown while sharing is off", () => {
    expect(line({ sharing: false, alerts: [] }, recovery([{ model: "m", at: NOW - MIN }]))).toBeNull();
  });
});

describe("advanceRecovery", () => {
  const board = (...models: string[]) => ({ errors: { alerts: models.map((model) => alert({ model })) } });
  const step = (previous: ErrorRecovery, models: string[] | null, at: number, over: Partial<CommunityErrorInput> = {}) =>
    advanceRecovery(
      previous,
      models === null ? null : board(...models),
      input({ alerts: models ? board(...models).errors.alerts : undefined, now: at, ...over }),
    );

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

  it("does not count a skipped own-report alert as shown", () => {
    const groups = [group({ agoMs: 10 * MIN })];
    const own = (models: string[]) => models.map((model) => alert({ model, failingContributors: 1 }));
    const run = (previous: ErrorRecovery, models: string[], at: number) =>
      advanceRecovery(previous, { errors: { alerts: own(models) } }, input({ alerts: own(models), groups, now: at }));
    const state = run(NO_RECOVERY, ["claude-opus-5-5"], NOW);
    expect(state).toBe(NO_RECOVERY);
    expect(run(state, [], NOW + MIN)).toBe(NO_RECOVERY);
  });

  it("only follows alerts that were shown", () => {
    // Not relevant to the user: never shown, so nothing to recover from.
    const state = step(NO_RECOVERY, ["claude-opus-5-5"], NOW, { records: [] });
    expect(state).toBe(NO_RECOVERY);
    expect(step(state, [], NOW + MIN)).toBe(NO_RECOVERY);
  });

  it("follows the models named by Also as well", () => {
    const records = [turn("m-a"), turn("m-b")];
    let state = step(NO_RECOVERY, ["m-a", "m-b"], NOW, { records });
    expect(state.shown).toEqual(["m-a", "m-b"]);
    state = step(state, ["m-a"], NOW + MIN, { records });
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
