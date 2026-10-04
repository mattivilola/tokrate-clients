import type { Snapshot } from "../store/types";

export type Tone = "good" | "warn" | "muted" | "danger";

/** Footer text for monitoring: a calm dot unless something needs attention. */
export function monitoringState(snapshot: Snapshot): { label: string; tone: Tone } {
  if (!snapshot.settings.monitoring) return { label: "Paused", tone: "muted" };
  const problem =
    /could not|unavailable|unreadable|in memory|rejected/i.test(snapshot.monitorStatus);
  return problem
    ? { label: "Monitoring needs attention", tone: "warn" }
    : { label: "Monitoring", tone: "good" };
}

/** Same words as the Mac footer: Local only, Sharing on, Sharing needs attention, choice pending. */
export function sharingState(snapshot: Snapshot): { label: string; tone: Tone } {
  if (snapshot.consentPromptRequired)
    return { label: "Sharing choice pending", tone: "muted" };
  if (!snapshot.settings.sharing) return { label: "Local only", tone: "muted" };
  if (snapshot.status === "Sharing new turns" || snapshot.status.startsWith("Preview"))
    return { label: "Sharing on", tone: "good" };
  if (snapshot.status.startsWith("Opening"))
    return { label: "Starting sharing", tone: "muted" };
  return { label: "Sharing needs attention", tone: "warn" };
}
