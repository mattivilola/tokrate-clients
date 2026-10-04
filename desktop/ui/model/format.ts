import { PROVIDER_LABELS, client, clientLabel, type Metric } from "../metrics";
import type { SourceId } from "../store/types";

/** One decimal by default; an em dash when there is no value. */
export const num = (v: number | null | undefined, digits = 1) =>
  typeof v === "number" && Number.isFinite(v) ? v.toFixed(digits) : "—";

/** Gauge readout: whole numbers from 100 up keep the large number inside the dial. */
export const readout = (v: number | null | undefined) =>
  typeof v === "number" && Number.isFinite(v)
    ? v.toFixed(v >= 100 ? 0 : 1)
    : "—";

export const exactTime = (value: string | number) => {
  const t = typeof value === "string" ? Date.parse(value) : value;
  return Number.isFinite(t) ? new Date(t).toLocaleString() : "Unavailable";
};

/** "Oct 4, 2:00 PM": compact bucket time for chart tooltips. */
export const shortTime = (t: number) =>
  Number.isFinite(t)
    ? new Date(t).toLocaleString([], {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
      })
    : "Unavailable";

/** "+12%" / "−8%" with a typographic minus. */
export const signedPercent = (percent: number) => {
  const value = Math.round(percent);
  return value > 0 ? `+${value}%` : value < 0 ? `−${Math.abs(value)}%` : "0%";
};

export const SOURCE_TITLES: Record<SourceId, string> = {
  codex: "Codex",
  "claude-code": "Claude Code",
  "grok-build": "Grok Build",
};

/** Provider filter options in picker order: every attributable provider, then the unknown route. */
export const PROVIDER_TITLES: Record<string, string> = {
  ...PROVIDER_LABELS,
  unknown: "Unknown route",
};

export const modelName = (m: Metric | undefined) =>
  m?.model ?? "Unknown model";

/** "high effort", "effort unknown": the vocabulary word is part of the chip. */
export const effortChip = (m: Metric) =>
  m.reasoningEffort && m.reasoningEffort !== "unknown"
    ? `${m.reasoningEffort} effort`
    : "effort unknown";

/** "Claude Code · v2.1.0" style secondary line; qualifier only when entries would look identical. */
export const cohortSubtitle = (m: Metric, qualifier: string | null) =>
  [clientLabel(m), qualifier].filter(Boolean).join(" · ");

/** Single-line plain text for assistive tech and tooltips. */
export const cohortSummary = (m: Metric, qualifier: string | null = null) =>
  [
    modelName(m),
    clientLabel(m),
    m.reasoningEffort ? `${m.reasoningEffort} effort` : "effort unknown",
    qualifier,
  ]
    .filter(Boolean)
    .join(", ");

/** Compact folder name: the last path segment, with the full path left for a tooltip. */
export function folderName(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const parts = trimmed.split(/[\\/]/).filter(Boolean);
  if (!parts.length) return trimmed || "Default folder";
  const last = parts[parts.length - 1];
  const parent = parts[parts.length - 2];
  return parent ? `${parent}/${last}` : last;
}

export const sourceOf = (m: Metric): SourceId => client(m) as SourceId;
