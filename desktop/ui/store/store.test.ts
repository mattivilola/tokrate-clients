import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppStore, SHARING_NOTICE_VERSION } from "./store";
import type { Bridge, Snapshot } from "./types";

const snapshot = (over: Partial<Snapshot> = {}): Snapshot => ({
  settings: {
    sharing: false,
    monitoring: true,
    showSpeed: true,
    showProviderBadge: true,
    selection: "auto",
    days: 1,
    root: "",
    claudeRoot: "",
    grokRoot: "",
    antigravityRoot: "",
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
    retrySharing: unused,
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

  it("uses the consent notice version 3", () => {
    expect(SHARING_NOTICE_VERSION).toBe("2026-10-06-v4");
  });

  it("opens settings at an anchor once", () => {
    const store = new AppStore(bridge());
    store.openSettings("settings-updates");
    expect(store.getState().ui).toMatchObject({ view: "settings", settingsAnchor: "settings-updates" });
    store.clearSettingsAnchor();
    expect(store.getState().ui.settingsAnchor).toBeNull();
  });
});
