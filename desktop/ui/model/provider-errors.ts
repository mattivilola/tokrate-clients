import { DAY, relativeTime } from "../metrics";
import type { ProviderErrorGroup } from "../store/types";

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
