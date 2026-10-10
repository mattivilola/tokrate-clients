import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppStore, SHARING_NOTICE_VERSION } from "./store";
import { createPreviewBridge } from "./preview";
import type { Bridge, Snapshot } from "./types";

const snapshot = (over: Partial<Snapshot> = {}): Snapshot => ({
  settings: {
    sharing: false,
    monitoring: true,
    showSpeed: true,
    showProviderBadge: true,
    showToolChip: true,
    selection: "auto",
    days: 1,
    root: "",
    claudeRoot: "",
    grokRoot: "",
    antigravityRoot: "",
    opencodeRoot: "",
    kimiRoot: "",
    kimiDesktopRoot: "",
  },
  consentPromptRequired: true,
  records: [],
  status: "Choose",
  monitorStatus: "Monitoring",
  pending: 0,
  board: null,
  revision: 1,
  recordsChanged: true,
  sources: [],
  ...over,
});

let current = snapshot();
function bridge(over: Partial<Bridge> = {}): Bridge {
  const unused = () => Promise.reject(new Error("unused"));
  return {
    native: true,
    snapshot: async (since) => ({
      ...current,
      recordsChanged: since !== current.revision,
    }),
    updateSettings: async () => (current = snapshot({ consentPromptRequired: false })),
    recordSharingConsent: async () =>
      (current = snapshot({ consentPromptRequired: false })),
    setDashboardFilters: async () => {},
    retrySharing: unused,
    sentExample: async () => '{"example": true}',
    chooseFolder: unused,
    resetFolder: unused,
    openWebsite: async () => {},
    openHistory: async () => {},
    hideFlyout: async () => {},
    quit: async () => {},
    smokeComplete: async () => {},
    updatePreferences: unused,
    setAutomaticUpdateChecks: unused,
    checkUpdate: unused,
    installUpdate: unused,
    restartAfterUpdate: unused,
    ...over,
  };
}

beforeEach(() => {
  current = snapshot();
  vi.stubGlobal("document", { hidden: false, addEventListener() {}, removeEventListener() {} });
  vi.stubGlobal("window", { addEventListener() {}, removeEventListener() {} });
});
afterEach(() => vi.unstubAllGlobals());

describe("AppStore", () => {
  it("keeps the same snapshot object when a poll returns nothing new", async () => {
    const store = new AppStore(bridge());
    await store.refresh();
    const first = store.getState().snapshot;
    await store.refresh();
    expect(store.getState().snapshot).toBe(first);
    expect(store.getState().loaded).toBe(true);
  });

  it("moves to the last onboarding step only after the choice was saved", async () => {
    const record = vi.fn(async () => (current = snapshot({ consentPromptRequired: false })));
    const store = new AppStore(bridge({ recordSharingConsent: record }));
    await store.refresh();
    store.setOnboardingStep(1);
    await store.recordSharingChoice(false, true);
    expect(record).toHaveBeenCalledWith(false, expect.any(String));
    expect(store.getState().ui.onboardingStep).toBe(2);
    expect(store.getState().snapshot.consentPromptRequired).toBe(false);
  });

  it("keeps the pending choice on screen when saving fails", async () => {
    const store = new AppStore(
      bridge({ recordSharingConsent: async () => Promise.reject(new Error("disk")) }),
    );
    await store.refresh();
    store.setOnboardingStep(1);
    await store.recordSharingChoice(true, true);
    expect(store.getState().ui.onboardingStep).toBe(1);
    expect(store.getState().snapshot.consentPromptRequired).toBe(true);
    expect(store.getState().error).not.toBe("");
  });

  it("returns to Auto when a filter changes", async () => {
    const update = vi.fn(async (patch) =>
      snapshot({ settings: { ...snapshot().settings, ...patch }, consentPromptRequired: false }),
    );
    const store = new AppStore(bridge({ updateSettings: update }));
    await store.refresh();
    store.setToolFilter("claude-code");
    await vi.waitFor(() => expect(update).toHaveBeenCalledWith({ selection: "auto" }));
    expect(store.getState().ui.toolFilter).toBe("claude-code");
  });

  it("tells the shell the flyout's filters, at start and whenever one changes", async () => {
    const report = vi.fn(async () => {});
    const store = new AppStore(bridge({ setDashboardFilters: report }), { reportFilters: true });
    const stop = store.start();
    expect(report).toHaveBeenLastCalledWith("all", "all");
    store.setToolFilter("claude-code");
    expect(report).toHaveBeenLastCalledWith("claude-code", "all");
    store.setProviderFilter("anthropic");
    expect(report).toHaveBeenLastCalledWith("claude-code", "anthropic");
    expect(report).toHaveBeenCalledTimes(3);
    stop();
  });

  it("does not report filters from a window that did not ask (the history window)", async () => {
    const report = vi.fn(async () => {});
    const store = new AppStore(bridge({ setDashboardFilters: report }));
    const stop = store.start();
    store.setToolFilter("codex");
    expect(report).not.toHaveBeenCalled();
    stop();
  });

  it("loads the example upload from the shell once, at start", async () => {
    const example = vi.fn(async () => "{\n  \"schemaVersion\": 1\n}");
    const store = new AppStore(bridge({ sentExample: example }));
    expect(store.getState().sentExample).toEqual({ text: null, failed: false });
    const stop = store.start();
    await vi.waitFor(() =>
      expect(store.getState().sentExample).toEqual({
        text: "{\n  \"schemaVersion\": 1\n}",
        failed: false,
      }),
    );
    await store.refresh();
    expect(example).toHaveBeenCalledTimes(1);
    stop();
  });

  it("marks the example as failed when the shell cannot produce it", async () => {
    const store = new AppStore(bridge({ sentExample: () => Promise.reject(new Error("gone")) }));
    const stop = store.start();
    await vi.waitFor(() =>
      expect(store.getState().sentExample).toEqual({ text: null, failed: true }),
    );
    stop();
  });

  it("survives a failed filter report", async () => {
    const store = new AppStore(
      bridge({ setDashboardFilters: () => Promise.reject(new Error("gone")) }),
      { reportFilters: true },
    );
    store.setToolFilter("codex");
    await Promise.resolve();
    expect(store.getState().ui.toolFilter).toBe("codex");
    expect(store.getState().error).toBe("");
  });

  it("keeps the cached records when a poll brings only live data", async () => {
    const record = { id: "r1" } as Snapshot["records"][number];
    current = snapshot({ records: [record], revision: 4 });
    const store = new AppStore(bridge());
    await store.refresh();
    expect(store.getState().snapshot.records).toEqual([record]);
    const live = [
      { id: "l1", completedAt: "2026-10-06T10:00:00Z", client: "codex" },
    ] as unknown as NonNullable<Snapshot["live"]>;
    current = snapshot({ records: [record], revision: 4, live });
    let sent = -1;
    const poll = bridge().snapshot;
    store.bridge.snapshot = async (since) => {
      const next = await poll(since);
      sent = next.recordsChanged ? 1 : 0;
      return { ...next, records: next.recordsChanged ? next.records : [] };
    };
    await store.refresh();
    expect(sent).toBe(0);
    expect(store.getState().snapshot.live).toEqual(live);
    expect(store.getState().snapshot.records).toEqual([record]);
  });

  it("ignores a poll that was in flight when sharing was switched off", async () => {
    let release: (value: Snapshot) => void = () => {};
    const slow = new Promise<Snapshot>((resolve) => (release = resolve));
    let calls = 0;
    const store = new AppStore(
      bridge({
        snapshot: () =>
          ++calls === 2
            ? slow
            : Promise.resolve(
                snapshot({ consentPromptRequired: false, revision: calls, settings: { ...snapshot().settings, sharing: false } }),
              ),
        updateSettings: async () =>
          snapshot({ consentPromptRequired: false, revision: 2, settings: { ...snapshot().settings, sharing: false } }),
      }),
    );
    await store.refresh();
    const stale = store.refresh();
    await store.disableSharing();
    release(snapshot({ consentPromptRequired: false, revision: 1, settings: { ...snapshot().settings, sharing: true } }));
    await stale;
    expect(store.getState().snapshot.settings.sharing).toBe(false);
  });

  it("starts with an automatic chart metric and the response-ranked model list", () => {
    const store = new AppStore(bridge());
    expect(store.getState().ui).toMatchObject({
      chartMetric: null,
      modelsView: "response",
      sort: "throughput",
    });
    store.setModelsView("turn");
    expect(store.getState().ui.modelsView).toBe("turn");
    store.setChartMetric("response");
    expect(store.getState().ui.chartMetric).toBe("response");
  });

  it("uses the consent notice version 5", () => {
    expect(SHARING_NOTICE_VERSION).toBe("2026-10-09-v5");
  });

  it("lists Kimi Code as one source and filters by the Moonshot AI provider", async () => {
    const store = new AppStore(createPreviewBridge({ scenario: "default", view: "home" }));
    await store.refresh();
    const kimi = store.getState().snapshot.sources?.find((s) => s.id === "kimi-code");
    expect(kimi).toMatchObject({ root: "~/.kimi-code", isDefault: true, found: true });
    store.setToolFilter("kimi-code");
    store.setProviderFilter("moonshot");
    expect(store.getState().ui).toMatchObject({ toolFilter: "kimi-code", providerFilter: "moonshot" });
  });

  it("opens settings at an anchor once", () => {
    const store = new AppStore(bridge());
    store.openSettings("settings-updates");
    expect(store.getState().ui).toMatchObject({ view: "settings", settingsAnchor: "settings-updates" });
    store.clearSettingsAnchor();
    expect(store.getState().ui.settingsAnchor).toBeNull();
  });
});
