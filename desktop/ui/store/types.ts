import type { LiveResponse, Metric } from "../metrics";

export type SourceId = "codex" | "claude-code" | "grok-build";

export interface Settings {
  sharing: boolean;
  monitoring: boolean;
  showSpeed: boolean;
  /** Letter badge for the model's provider in the tray icon and the window. */
  showProviderBadge: boolean;
  /** `auto`, `auto:<tool>`, `all`, `model:[model,provider]` or a pinned nine-part cohort. */
  selection: string;
  days: number;
  root: string;
  claudeRoot: string;
  grokRoot: string;
}

/** Detected state of one coding-tool log folder (the path stays on the device). */
export interface SourceStatus {
  id: SourceId;
  root: string;
  isDefault: boolean;
  found: boolean;
}

export interface CommunityCohort {
  id: string;
  model?: string | null;
  reasoningEffort?: string | null;
  client?: string | null;
  provider?: string | null;
  contributors?: number;
  turns?: number;
  throughputTurns?: number;
  ttftTurns?: number;
  medianThroughput?: number | null;
  medianTtftMs?: number | null;
  signals?: {
    throughput?: { state?: string };
    ttft?: { state?: string };
  };
}

export interface CommunityAlert {
  cohortId?: unknown;
  message?: string;
  metric?: string;
  state?: string;
}

/** Published community board; every field is optional so older cached responses decode. */
export interface Board {
  window?: string;
  state?: string;
  dataAsOf?: string;
  methodology?: { publicationMode?: string };
  cohorts?: CommunityCohort[];
  alerts?: CommunityAlert[];
}

export interface Snapshot {
  settings: Settings;
  consentPromptRequired: boolean;
  records: Metric[];
  status: string;
  monitorStatus: string;
  pending: number;
  board: Board | null;
  revision: number;
  recordsChanged: boolean;
  sources?: SourceStatus[];
  smoke?: boolean;
  /** Qualifying responses completed since launch, oldest first (local only). */
  live?: LiveResponse[];
  /** The model an Auto selection follows while live responses exist; null otherwise. */
  active?: { model: string | null; provider: string | null } | null;
}

export type SettingsPatch = Partial<
  Pick<
    Settings,
    "sharing" | "monitoring" | "showSpeed" | "showProviderBadge" | "selection" | "days"
  >
>;

export interface UpdatePreferences {
  automaticChecks: boolean;
  mode: "native" | "manual" | "unavailable";
  settingsWarning: string | null;
  currentVersion: string;
}
export interface UpdateSummary {
  version: string;
  body: string | null;
}
export interface UpdateCheckResult {
  started: boolean;
  update: UpdateSummary | null;
}
export type UpdateDownloadEvent =
  | { event: "Started"; data: { contentLength?: number | null } }
  | { event: "Progress"; data: { chunkLength: number } }
  | { event: "Finished"; data?: undefined };

export type WebsitePage = "home" | "privacy" | "terms" | "desktop-downloads";

/** The narrow command surface of the native shell; the browser preview supplies a synthetic one. */
export interface Bridge {
  readonly native: boolean;
  snapshot(sinceRevision: number | null): Promise<Snapshot>;
  updateSettings(patch: SettingsPatch): Promise<Snapshot>;
  recordSharingConsent(accepted: boolean, noticeVersion: string): Promise<Snapshot>;
  retrySharing(): Promise<Snapshot>;
  chooseFolder(source: SourceId): Promise<Snapshot>;
  resetFolder(source: SourceId): Promise<Snapshot>;
  openWebsite(page: WebsitePage): Promise<void>;
  openHistory(): Promise<void>;
  hideFlyout(): Promise<void>;
  quit(): Promise<void>;
  smokeComplete(): Promise<void>;
  updatePreferences(): Promise<UpdatePreferences>;
  setAutomaticUpdateChecks(enabled: boolean): Promise<UpdatePreferences>;
  checkUpdate(automatic: boolean): Promise<UpdateCheckResult>;
  installUpdate(onEvent: (event: UpdateDownloadEvent) => void): Promise<void>;
  restartAfterUpdate(): Promise<void>;
}

export type ToolFilter = "all" | SourceId;
export type ProviderFilter =
  | "all"
  | "openai"
  | "anthropic"
  | "amazon-bedrock"
  | "google-vertex"
  | "xai"
  | "unknown";
export type ChartMetric = "response" | "throughput" | "ttft";
/** Model lists rank by response speed or keep the per-measurement turn groups. */
export type ModelsView = "response" | "turn";
export type View = "home" | "settings";

export interface UiState {
  view: View;
  toolFilter: ToolFilter;
  providerFilter: ProviderFilter;
  chartMetric: ChartMetric;
  sort: "recent" | "throughput" | "ttft";
  modelsView: ModelsView;
  /** 0 welcome, 1 sharing choice, 2 where to find Tokrate. */
  onboardingStep: 0 | 1 | 2;
  /** Section id to scroll to when Settings opens (for example the update banner's Details). */
  settingsAnchor: string | null;
  /** The sharing notice sheet opened from Settings (never the first-run flow). */
  consentSheetOpen: boolean;
}

export interface UpdateUiState {
  preferences: UpdatePreferences | null;
  loaded: boolean;
  checkInFlight: boolean;
  installInFlight: boolean;
  available: UpdateSummary | null;
  status: string;
  progress: { downloaded: number; total: number };
}

export interface AppState {
  snapshot: Snapshot;
  loaded: boolean;
  /** Wall clock captured at the last poll; relative times and ranges derive from it. */
  now: number;
  error: string;
  busy: boolean;
  update: UpdateUiState;
  ui: UiState;
}
