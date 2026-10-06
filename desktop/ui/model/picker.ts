import { client, measurementChip, type CohortRow, type Metric } from "../metrics";
import { fallbackModel, providerName, sameModel, type ToolId } from "../response";
import type { Dashboard } from "./dashboard";
import { effortChip, modelName } from "./format";

/** Exact cohorts offered above "More models". */
export const RECENT_MODEL_LIMIT = 5;

/** "Model · effort · Subagent": a cohort without its version or provider qualifiers. */
export const cohortBaseTitle = (m: Metric) =>
  [modelName(m), effortChip(m).replace(" effort", ""), measurementChip(m)]
    .filter(Boolean)
    .join(" · ");

export interface RecentModelRow {
  /** The newest exact cohort of the group; selecting the entry picks this cohort. */
  row: CohortRow;
  title: string;
}

/** Rows that differ only by client, parser or metric version are the same model to the reader. */
const recentGroupKey = (m: Metric) =>
  JSON.stringify([
    client(m),
    m.model ?? null,
    effortChip(m),
    measurementChip(m),
    m.provider ?? "unknown",
    m.providerRegion ?? null,
  ]);

/**
 * The most recently used models, newest first: one entry per client, model, effort, measurement
 * and provider route (the newest cohort of each), without rows that carry no model. The provider
 * is spelled out only when two entries of one coding tool would otherwise read the same.
 */
export function recentModelRows(
  cohorts: CohortRow[],
  limit = RECENT_MODEL_LIMIT,
): RecentModelRow[] {
  const newest = new Map<string, CohortRow>();
  for (const row of cohorts) {
    if (row.sample.model == null) continue;
    const key = recentGroupKey(row.sample);
    const kept = newest.get(key);
    if (!kept || row.latestAt > kept.latestAt) newest.set(key, row);
  }
  const rows = [...newest.values()].sort((a, b) => b.latestAt - a.latestAt).slice(0, limit);
  const readAs = (row: CohortRow) => `${client(row.sample)}\u001f${cohortBaseTitle(row.sample)}`;
  const counts = new Map<string, number>();
  for (const row of rows) counts.set(readAs(row), (counts.get(readAs(row)) ?? 0) + 1);
  return rows.map((row) => {
    const base = cohortBaseTitle(row.sample);
    return {
      row,
      title:
        (counts.get(readAs(row)) ?? 0) > 1
          ? `${base} · ${providerName(row.sample.provider)}`
          : base,
    };
  });
}

/**
 * "claude-opus-5-5 · high": the model a coding tool is on, for its Auto option. Follows the same
 * rule as the hero (newest turn with response data) unless Auto already runs in this tool, where
 * the hero's own model wins. Null when the tool has no model.
 */
export function toolModelHint(
  dashboard: Pick<Dashboard, "filtered" | "mode" | "activeKey">,
  tool: ToolId,
): string | null {
  const records = dashboard.filtered.filter((m) => client(m) === tool);
  const { mode } = dashboard;
  const key = mode.kind === "auto" && mode.tool === tool ? dashboard.activeKey : fallbackModel(records);
  if (!key?.model) return null;
  const effort = records.find((m) => sameModel(m, key))?.reasoningEffort;
  return [key.model, effort && effort !== "unknown" ? effort : null].filter(Boolean).join(" · ");
}
