import { Channel, invoke } from "@tauri-apps/api/core";
import type {
  Bridge,
  Snapshot,
  UpdateCheckResult,
  UpdateDownloadEvent,
  UpdatePreferences,
} from "./types";

/** The only place that talks to the Rust shell. Raw logs and signing keys never cross this boundary. */
export const tauriBridge: Bridge = {
  native: true,
  snapshot: (sinceRevision) => invoke<Snapshot>("snapshot", { sinceRevision }),
  updateSettings: (patch) => invoke<Snapshot>("update_settings", { patch }),
  recordSharingConsent: (accepted, noticeVersion) =>
    invoke<Snapshot>("record_sharing_consent", { accepted, noticeVersion }),
  setDashboardFilters: (tool, provider) =>
    invoke("set_dashboard_filters", { tool, provider }),
  retrySharing: () => invoke<Snapshot>("retry_sharing"),
  sentExample: () => invoke<string>("sent_example"),
  chooseFolder: (source) => invoke<Snapshot>("choose_folder", { source }),
  resetFolder: (source) => invoke<Snapshot>("reset_folder", { source }),
  openWebsite: (page) => invoke("open_website", { page }),
  openHistory: () => invoke("open_history"),
  hideFlyout: () => invoke("hide_flyout"),
  quit: () => invoke("quit"),
  smokeComplete: () => invoke("smoke_complete"),
  updatePreferences: () => invoke<UpdatePreferences>("update_preferences"),
  setAutomaticUpdateChecks: (enabled) =>
    invoke<UpdatePreferences>("set_automatic_update_checks", { enabled }),
  checkUpdate: (automatic) =>
    invoke<UpdateCheckResult>(
      automatic ? "check_update_automatically" : "check_update",
    ),
  installUpdate: (onEvent) => {
    const channel = new Channel<UpdateDownloadEvent>();
    channel.onmessage = onEvent;
    return invoke("install_update", { onEvent: channel });
  },
  restartAfterUpdate: () => invoke("restart_after_update"),
};
