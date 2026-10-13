import { DAY, relativeTime } from "../metrics";
import type {
  Board,
  ErrorRecovery,
  ProviderErrorGroup,
  RelevantErrorAlert,
} from "../store/types";

/** Other groups named after the main one, "Also: {model} ({n})". */
const MAX_ALSO = 2;

const times = (count: number) => (count === 1 ? "time" : "times");

/**
 * The passive line about the user's own provider-side failures (contract "Local provider errors
 * (0.1.23)"), or null when no failure happened in the last 24 hours. The main group is the one
 * with the most recent failure; models are named as the tools report them.
 */
export function providerErrorLine(
  groups: readonly ProviderErrorGroup[] | undefined,
  now: number,
): string | null {
  const recent = (groups ?? [])
    .map((group) => ({ group, at: Date.parse(group.latestAt) }))
    .filter(({ at }) => Number.isFinite(at) && now - at <= DAY)
    .sort((a, b) => b.at - a.at);
  const main = recent[0];
  if (!main) return null;
  const { group, at } = main;
  const ago = relativeTime(at, now);
  const line =
    group.kind === "overloaded"
      ? `You hit “${group.client === "codex" ? "model at capacity" : "overloaded"}” ${group.count} ${times(group.count)} on ${group.model} in the last 24 hours, most recently ${ago}. That’s the provider at capacity, not your connection.`
      : `${group.model} returned ${group.count} server ${group.count === 1 ? "error" : "errors"} in the last 24 hours, most recently ${ago}. That’s a failure at the provider, not your connection.`;
  const also = recent
    .slice(1, 1 + MAX_ALSO)
    .map(({ group: other }) => `${other.model} (${other.count})`);
  return also.length ? `${line} Also: ${also.join(", ")}` : line;
}

/** How long the "no longer report" line stays. */
export const RECOVERY_MS = 30 * 60_000;

export const NO_RECOVERY: ErrorRecovery = { shown: [], cleared: [] };

export interface CommunityErrorInput {
  /**
   * The community alerts that concern the user, most relevant first, as the native shell selects
   * them (also for the notifications); ignored while sharing is off.
   */
  relevant: readonly RelevantErrorAlert[] | undefined;
  sharing: boolean;
  now: number;
}

export interface CommunityErrorLine {
  kind: "alert" | "recovery";
  text: string;
  /** The models the line names (alert lines only). */
  models: string[];
}

const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const contributors = (n: number) => count(n, "contributor", "contributors");

/** The alert's form for the user, after the contract's "The community line". */
function alertText(alert: RelevantErrorAlert, now: number): string {
  if (alert.notJustYou)
    return `It’s not just you: ${alert.others} other ${alert.others === 1 ? "contributor" : "contributors"} hit provider errors on ${alert.model} in the last hour.`;
  const counts = [
    alert.overloaded > 0 ? `${alert.overloaded} overloaded / at capacity` : null,
    alert.serverError > 0 ? count(alert.serverError, "server error", "server errors") : null,
  ]
    .filter((part) => part !== null)
    .join(" and ");
  return `Tokrate contributors are reporting provider errors on ${alert.model}: ${counts} from ${contributors(alert.failingContributors)} in the last hour, latest ${relativeTime(Date.parse(alert.lastFailureAt), now)}.`;
}

/**
 * The community alert line (contract "Community error alerts (0.1.23)"), or null when sharing is
 * off or no alert concerns the user. It words the most relevant alert and names up to two more
 * models; which alerts concern the user is decided by the native shell.
 */
export function communityAlertLine({
  relevant,
  sharing,
  now,
}: CommunityErrorInput): CommunityErrorLine | null {
  const main = sharing ? relevant?.[0] : undefined;
  if (!main) return null;
  const also = [...new Set((relevant ?? []).slice(1).map((alert) => alert.model))]
    .filter((model) => model !== main.model)
    .slice(0, MAX_ALSO);
  const line = alertText(main, now);
  return {
    kind: "alert",
    text: also.length ? `${line} Also: ${also.join(", ")}` : line,
    models: [main.model, ...also],
  };
}

/**
 * The line under the local one: the alert line, else for 30 minutes the recovery of the model
 * that cleared last. Null when neither applies.
 */
export function communityErrorLine(
  input: CommunityErrorInput,
  recovery: ErrorRecovery,
): CommunityErrorLine | null {
  const alert = communityAlertLine(input);
  if (alert || !input.sharing) return alert;
  const cleared = recovery.cleared
    .filter(({ at }) => input.now - at < RECOVERY_MS)
    .sort((a, b) => b.at - a.at)[0];
  return cleared
    ? {
        kind: "recovery",
        text: `${cleared.model}: contributors no longer report provider errors (cleared ${relativeTime(cleared.at, input.now)}).`,
        models: [],
      }
    : null;
}

/** The muted hint after the local line while sharing is off. */
export const SHARING_HINT = "Turn on sharing to see whether other contributors hit the same errors.";

/**
 * Follows the board across polls. A model whose alert line was shown and that is no longer among
 * the board's alerts is cleared at `now`; sharing off forgets everything, and a poll without a
 * board (unreachable server) learns nothing.
 */
export function advanceRecovery(
  previous: ErrorRecovery,
  board: Pick<Board, "errors"> | null,
  input: CommunityErrorInput,
): ErrorRecovery {
  if (!input.sharing)
    return previous.shown.length || previous.cleared.length ? NO_RECOVERY : previous;
  if (!board) return previous;
  const present = new Set((board.errors?.alerts ?? []).map((a) => a.model));
  const gone = previous.shown.filter((model) => !present.has(model));
  const cleared = [
    ...previous.cleared.filter(
      ({ model, at }) => !present.has(model) && input.now - at < RECOVERY_MS,
    ),
    ...gone.map((model) => ({ model, at: input.now })),
  ];
  const shown = [
    ...new Set([
      ...previous.shown.filter((model) => present.has(model)),
      ...(communityAlertLine(input)?.models ?? []),
    ]),
  ];
  const same =
    shown.length === previous.shown.length &&
    shown.every((model, i) => model === previous.shown[i]) &&
    cleared.length === previous.cleared.length &&
    cleared.every((entry, i) => entry.model === previous.cleared[i]?.model && entry.at === previous.cleared[i]?.at);
  return same ? previous : { shown, cleared };
}
