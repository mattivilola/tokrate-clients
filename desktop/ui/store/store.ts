import { useSyncExternalStore } from "react";
import { AsyncGate } from "../async-gate";
import type {
  AppState,
  Bridge,
  ChartMetric,
  ModelsView,
  ProviderFilter,
  SettingsPatch,
  Snapshot,
  SourceId,
  ToolFilter,
  UiState,
  UpdateDownloadEvent,
  View,
  WebsitePage,
} from "./types";

/** Bump together with the notice text in docs and the Rust constant. */
export const SHARING_NOTICE_VERSION = "2026-10-06-v4";
const MONITOR_UNREACHABLE =
  "Cannot reach the local monitor. Restart Tokrate to reconnect.";
const AUTOMATIC_UPDATE_REVISIT_MS = 60 * 60 * 1000;
const POLL_MS = 5000;
/** Relative times and ranges follow the wall clock at most this stale between data changes. */
const NOW_REFRESH_MS = 30000;

const EMPTY_SNAPSHOT: Snapshot = {
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
  consentPromptRequired: false,
  records: [],
  status: "Loading local settings…",
  monitorStatus: "Starting monitoring…",
  pending: 0,
  board: null,
  revision: -1,
  recordsChanged: true,
  sources: [],
};

export interface StoreOptions {
  initialView?: View;
  initialSelection?: string;
}

/**
 * Owns the command/poll layer. Components subscribe through `useStore`; polling replaces only the
 * parts of the state that changed, so mounted inputs keep their focus, scroll and transitions.
 */
export class AppStore {
  private state: AppState;
  private listeners = new Set<() => void>();
  private gate = new AsyncGate();
  private timers: ReturnType<typeof setInterval>[] = [];
  private started = 0;

  constructor(
    readonly bridge: Bridge,
    options: StoreOptions = {},
  ) {
    this.state = {
      snapshot: EMPTY_SNAPSHOT,
      loaded: false,
      now: Date.now(),
      error: "",
      busy: false,
      update: {
        preferences: null,
        loaded: false,
        checkInFlight: false,
        installInFlight: false,
        available: null,
        status: "Loading update preferences…",
        progress: { downloaded: 0, total: 0 },
      },
      ui: {
        view: options.initialView ?? "home",
        toolFilter: "all",
        providerFilter: "all",
        chartMetric: null,
        sort: "throughput",
        modelsView: "response",
        onboardingStep: 0,
        settingsAnchor: null,
        consentSheetOpen: false,
      },
    };
  }

  // --- subscription -------------------------------------------------------
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getState = () => this.state;
  private set(next: Partial<AppState>) {
    this.state = { ...this.state, ...next };
    this.listeners.forEach((l) => l());
  }
  private setUi(next: Partial<UiState>) {
    this.set({ ui: { ...this.state.ui, ...next } });
  }
  private setUpdate(next: Partial<AppState["update"]>) {
    this.set({ update: { ...this.state.update, ...next } });
  }

  // --- lifecycle ----------------------------------------------------------
  /** Idempotent: React StrictMode mounts effects twice in development. */
  start = () => {
    if (this.started++ > 0) return this.stop;
    void this.refresh();
    const onVisible = () => {
      if (!document.hidden) void this.refresh();
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    this.timers = [
      setInterval(() => void this.refresh(), POLL_MS),
      setInterval(() => {
        const { update, snapshot } = this.state;
        if (
          !snapshot.smoke &&
          update.preferences?.mode === "native" &&
          update.preferences.automaticChecks
        )
          void this.checkForUpdates(true);
      }, AUTOMATIC_UPDATE_REVISIT_MS),
    ];
    this.cleanup = () => {
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
    };
    return this.stop;
  };
  private cleanup = () => {};
  stop = () => {
    if (--this.started > 0) return;
    this.timers.forEach(clearInterval);
    this.timers = [];
    this.cleanup();
  };

  // --- UI state -----------------------------------------------------------
  setView = (view: View) => this.setUi({ view });
  openSettings = (anchor: string | null = null) =>
    this.setUi({ view: "settings", settingsAnchor: anchor });
  clearSettingsAnchor = () => this.setUi({ settingsAnchor: null });
  setChartMetric = (chartMetric: ChartMetric) => this.setUi({ chartMetric });
  setSort = (sort: UiState["sort"]) => this.setUi({ sort });
  setModelsView = (modelsView: ModelsView) => this.setUi({ modelsView });
  setOnboardingStep = (onboardingStep: UiState["onboardingStep"]) =>
    this.setUi({ onboardingStep });
  setConsentSheet = (consentSheetOpen: boolean) =>
    this.setUi({ consentSheetOpen });
  /** Changing a filter returns to Auto (most active), the default selection. */
  setToolFilter = (toolFilter: ToolFilter) => {
    this.setUi({ toolFilter });
    void this.patch({ selection: "auto" });
  };
  setProviderFilter = (providerFilter: ProviderFilter) => {
    this.setUi({ providerFilter });
    void this.patch({ selection: "auto" });
  };

  // --- commands -----------------------------------------------------------
  private async action(fn: () => Promise<Snapshot | void>) {
    const epoch = this.gate.beginMutation();
    this.set({ busy: true });
    try {
      const next = await fn();
      if (this.gate.isLatest(epoch)) {
        if (next) this.set({ snapshot: this.merge(next), error: "" });
        else this.set({ error: "" });
      }
    } catch {
      if (this.gate.isLatest(epoch))
        this.set({
          error:
            "The change could not be saved. Review your settings and try again.",
        });
    } finally {
      this.gate.finishMutation();
      const busy = this.gate.pending > 0;
      this.set({ busy });
      if (!busy) void this.refresh();
    }
  }
  /** A mutation response without records (revision unchanged) keeps the cached records. */
  private merge(next: Snapshot): Snapshot {
    return next.recordsChanged
      ? next
      : { ...next, records: this.state.snapshot.records };
  }
  patch = (patch: SettingsPatch) =>
    this.action(() => this.bridge.updateSettings(patch));
  selectCohort = (selection: string) => this.patch({ selection });
  setDays = (days: 1 | 7) => this.patch({ days });
  disableSharing = () => this.patch({ sharing: false });
  /**
   * `fromOnboarding` moves to the last onboarding step only after the choice was saved, so a
   * failed save keeps the sharing step (and the pending prompt) on screen.
   */
  recordSharingChoice = async (accepted: boolean, fromOnboarding = false) => {
    await this.action(async () => {
      const next = await this.bridge.recordSharingConsent(
        accepted,
        SHARING_NOTICE_VERSION,
      );
      this.setUi(
        fromOnboarding
          ? { onboardingStep: 2, consentSheetOpen: false }
          : { consentSheetOpen: false },
      );
      return next;
    });
  };
  retrySharing = () => this.action(() => this.bridge.retrySharing());
  chooseFolder = (source: SourceId) =>
    this.action(() => this.bridge.chooseFolder(source));
  resetFolder = (source: SourceId) =>
    this.action(() => this.bridge.resetFolder(source));
  openWebsite = (page: WebsitePage) => void this.bridge.openWebsite(page);
  openHistory = () => void this.bridge.openHistory();
  hideFlyout = () => void this.bridge.hideFlyout();
  quit = () => void this.bridge.quit();
  smokeComplete = () => this.bridge.smokeComplete();
  dismissError = () => this.set({ error: "" });

  // --- polling ------------------------------------------------------------
  refresh = async () => {
    // First load always runs; later polls pause while the flyout is hidden (never in smoke runs).
    const { busy, loaded, snapshot: current } = this.state;
    if (busy || (loaded && document.hidden && !current.smoke)) return;
    const epoch = this.gate.epoch;
    try {
      const { snapshot, loaded, now } = this.state;
      const next = await this.bridge.snapshot(
        snapshot.revision < 0 ? null : snapshot.revision,
      );
      if (!this.gate.accepts(epoch)) return;
      const clock = Date.now();
      const changed =
        !loaded ||
        next.recordsChanged ||
        JSON.stringify({ ...next, records: [] }) !==
          JSON.stringify({ ...snapshot, records: [], recordsChanged: false });
      // A recovered monitor clears its own message; save errors stay until the next action.
      const error =
        this.state.error === MONITOR_UNREACHABLE ? "" : this.state.error;
      if (changed)
        this.set({
          snapshot: this.merge(next),
          loaded: true,
          now: clock,
          error,
        });
      else if (clock - now >= NOW_REFRESH_MS || error !== this.state.error)
        this.set({ now: clock, error });
      if (!this.state.update.loaded) void this.loadUpdatePreferences();
    } catch {
      this.set({ error: MONITOR_UNREACHABLE });
    }
  };

  // --- updates ------------------------------------------------------------
  async loadUpdatePreferences() {
    if (this.state.update.loaded) return;
    this.setUpdate({ loaded: true });
    try {
      const preferences = await this.bridge.updatePreferences();
      const smoke = this.state.snapshot.smoke;
      const status = smoke
        ? "Updater networking is disabled in native smoke runs."
        : preferences.mode === "manual"
          ? "Debian package updates are installed manually."
          : preferences.mode === "unavailable"
            ? "This installation does not support in-app updates."
            : preferences.automaticChecks
              ? "Automatic checks are on. Updates require your click to install."
              : "Automatic checks are off. You can still check manually.";
      this.setUpdate({ preferences, status });
      if (!smoke && preferences.mode === "native" && preferences.automaticChecks)
        void this.checkForUpdates(true);
    } catch {
      this.setUpdate({ status: "Update preferences could not be loaded." });
    }
  }
  setAutomaticUpdateChecks = async (enabled: boolean) => {
    if (!this.state.update.preferences) return;
    try {
      const preferences = await this.bridge.setAutomaticUpdateChecks(enabled);
      this.setUpdate({
        preferences,
        status: enabled
          ? "Automatic checks are on. Updates require your click to install."
          : "Automatic checks are off. You can still check manually.",
      });
      if (enabled) void this.checkForUpdates(true);
    } catch {
      this.setUpdate({ status: "Update preference could not be saved." });
    }
  };
  checkForUpdates = async (automatic: boolean) => {
    const { update, snapshot } = this.state;
    if (
      snapshot.smoke ||
      !update.preferences ||
      update.checkInFlight ||
      update.installInFlight ||
      update.preferences.mode !== "native"
    )
      return;
    this.setUpdate({
      checkInFlight: true,
      status: "Checking Tokrate’s signed update feed…",
    });
    try {
      const result = await this.bridge.checkUpdate(automatic);
      if (!result.started) {
        this.setUpdate({
          status: automatic
            ? "The automatic check is throttled. You can check manually."
            : "An update check is already in progress.",
        });
        return;
      }
      this.setUpdate({
        available: result.update,
        status: result.update
          ? `Version ${result.update.version} is ready if you choose to install it.`
          : `Tokrate ${update.preferences.currentVersion} is up to date.`,
      });
    } catch {
      this.setUpdate({
        status: "Could not check for updates. Check your connection and try again.",
      });
    } finally {
      this.setUpdate({ checkInFlight: false });
    }
  };
  installAvailableUpdate = async () => {
    const { update, snapshot } = this.state;
    if (
      snapshot.smoke ||
      !update.available ||
      update.installInFlight ||
      update.checkInFlight
    )
      return;
    this.setUpdate({
      installInFlight: true,
      progress: { downloaded: 0, total: 0 },
      status: "Downloading and verifying the signed update…",
    });
    try {
      await this.bridge.installUpdate((event: UpdateDownloadEvent) => {
        const progress = this.state.update.progress;
        if (event.event === "Started")
          this.setUpdate({
            progress: { downloaded: 0, total: event.data.contentLength ?? 0 },
          });
        else if (event.event === "Progress")
          this.setUpdate({
            progress: {
              ...progress,
              downloaded: progress.downloaded + event.data.chunkLength,
            },
          });
      });
      this.setUpdate({
        available: null,
        status: "Update installed. Restarting Tokrate…",
      });
    } catch {
      this.setUpdate({
        installInFlight: false,
        status:
          "The signed update could not be verified or installed. Your current version remains active.",
      });
      return;
    }
    try {
      await this.bridge.restartAfterUpdate();
    } catch {
      this.setUpdate({
        installInFlight: false,
        status:
          "The update is installed. Quit and reopen Tokrate to finish applying it.",
      });
    }
  };
}

export function useStore<T>(store: AppStore, select: (state: AppState) => T): T {
  return useSyncExternalStore(store.subscribe, () => select(store.getState()));
}
