import { ArrowLeft, Columns2 } from "lucide-react";
import {
  clientLabel,
  communityId,
  measurementChip,
  measurementTitle,
  metricDefinition,
  parserVersion,
  metricVersion,
  type CohortRow,
  type SortKey,
} from "../metrics";
import type { Board } from "../store/types";
import type { Dashboard } from "../model/dashboard";
import { cohortSubtitle, effortChip, modelName, num } from "../model/format";
import { useStore } from "../store/store";
import { Chip, useAppStore } from "./primitives";

function ModelRow({
  row,
  selected,
  max,
  onSelect,
  detailed,
  community,
}: {
  row: CohortRow;
  selected: boolean;
  max: number;
  onSelect: () => void;
  detailed: boolean;
  community: number | null;
}) {
  const { sample, stats, qualifier } = row;
  const median = stats.throughput.median;
  const chip = measurementChip(sample);
  const fill = median !== null && max > 0 ? Math.max(4, (median / max) * 100) : 0;
  const title = [
    `${modelName(sample)} · ${clientLabel(sample)} ${sample.clientVersion ?? "version unknown"}`,
    `${measurementTitle(sample)} · ${parserVersion(sample)} / ${metricVersion(sample)}`,
    `${stats.throughput.count} turns with turn speed · ${stats.ttft.count} with first-token time`,
  ].join("\n");
  return (
    <li>
      <button
        type="button"
        className="model-row"
        aria-current={selected || undefined}
        title={title}
        onClick={onSelect}
      >
        <span className="model-main">
          <span className="model-name">
            <span className="model-name-text">{modelName(sample)}</span>
            <Chip tone={effortChip(sample) === "effort unknown" ? "neutral" : "accent"}>
              {effortChip(sample)}
            </Chip>
            {chip && <Chip>{chip}</Chip>}
          </span>
          <span className="model-sub">
            {cohortSubtitle(sample, qualifier)}
            {detailed && (
              <>
                {" · "}
                {stats.throughput.count} {stats.throughput.count === 1 ? "turn" : "turns"}
                {stats.ttft.median !== null && <> · {num(stats.ttft.median)} s first token</>}
                {community !== null && <> · community {num(community, 0)} tok/s</>}
              </>
            )}
          </span>
        </span>
        <span className="model-value">
          <span className="model-number">
            {num(median)}
            <small> tok/s</small>
          </span>
          <span className="minibar" aria-hidden="true">
            <span style={{ width: `${fill}%` }} />
          </span>
        </span>
      </button>
    </li>
  );
}

/** Bars compare only turns measured the same way. */
function maxByDefinition(rows: CohortRow[]) {
  const max = new Map<string, number>();
  for (const row of rows) {
    const key = metricDefinition(row.sample);
    max.set(key, Math.max(max.get(key) ?? 0, row.stats.throughput.median ?? 0));
  }
  return max;
}

function communityMedians(board: Board | null) {
  const map = new Map<string, number>();
  for (const c of board?.cohorts ?? [])
    if (typeof c.medianThroughput === "number" && c.medianThroughput > 0)
      map.set(c.id, c.medianThroughput);
  return map;
}

export function YourModels({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const selection = useStore(store, (s) => s.snapshot.settings.selection);
  const max = maxByDefinition(dashboard.cohorts);
  if (!dashboard.cohorts.length) return null;
  return (
    <section className="models" aria-labelledby="your-models">
      <div className="section-head">
        <h2 id="your-models">Your models</h2>
        <button
          type="button"
          className="text-button"
          onClick={() => void store.selectCohort("all")}
        >
          <Columns2 size={16} aria-hidden="true" />
          Compare all
        </button>
      </div>
      <ul className="model-list">
        {dashboard.cohorts.map((row) => (
          <ModelRow
            key={row.key}
            row={row}
            selected={selection !== "all" && dashboard.selectedKey === row.key}
            max={max.get(metricDefinition(row.sample)) ?? 0}
            detailed={false}
            community={null}
            onSelect={() => void store.selectCohort(row.key)}
          />
        ))}
      </ul>
    </section>
  );
}

const SORTS: { value: SortKey; label: string }[] = [
  { value: "recent", label: "Most recent" },
  { value: "throughput", label: "Higher turn speed" },
  { value: "ttft", label: "Lower first token" },
];

/** "Compare all": the model list becomes the content, with a sort control. */
export function CompareAll({
  dashboard,
  board,
}: {
  dashboard: Dashboard;
  board: Board | null;
}) {
  const store = useAppStore();
  const sort = useStore(store, (s) => s.ui.sort);
  const rows = dashboard.sortedCohorts;
  const max = maxByDefinition(rows);
  const community = communityMedians(board);
  const dayLabel = dashboard.days === 1 ? "24 h" : "7 d";
  return (
    <section className="card compare" aria-labelledby="compare-title">
      <div className="section-head">
        <h1 id="compare-title">All models</h1>
        <label className="sort">
          <span className="visually-hidden">Sort models by</span>
          <select value={sort} onChange={(e) => store.setSort(e.target.value as SortKey)}>
            {SORTS.map((s) => (
              <option key={s.value} value={s.value}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
      </div>
      <p className="muted-line">Median turn speed over the last {dayLabel}.</p>
      {rows.length ? (
        <ul className="model-list model-list-flush">
          {rows.map((row) => (
            <ModelRow
              key={row.key}
              row={row}
              selected={false}
              max={max.get(metricDefinition(row.sample)) ?? 0}
              detailed
              community={community.get(communityId(row.sample)) ?? null}
              onSelect={() => void store.selectCohort(row.key)}
            />
          ))}
        </ul>
      ) : (
        <p className="empty">Complete a supported coding-tool turn to compare models.</p>
      )}
      <p className="fine">
        Different workloads and measurement definitions affect these numbers.
        Subagent, Work-turn and whole-turn speeds are never ranked against each other, and
        this is not an answer-quality ranking.
      </p>
      <button type="button" className="text-button back" onClick={() => void store.selectCohort("latest")}>
        <ArrowLeft size={16} aria-hidden="true" />
        Back to latest model
      </button>
    </section>
  );
}
