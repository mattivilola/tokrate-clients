import { ArrowLeft, Columns2 } from "lucide-react";
import {
  clientLabel,
  GROK_RESPONSE_EXPLANATION,
  GROK_RESPONSE_NOTE,
  communityId,
  measurementTitle,
  toolLabel,
  parserVersion,
  metricVersion,
  type CohortGroup,
  type CohortRow,
  type SortKey,
} from "../metrics";
import type { Board } from "../store/types";
import type { Dashboard } from "../model/dashboard";
import { effortChip, modelName, num } from "../model/format";
import { useStore } from "../store/store";
import {
  modelSelection,
  niceMedianMax,
  providerName,
  sortModelRows,
  type ModelSort,
  type ModelSpeedRow,
} from "../response";
import type { ModelsView } from "../store/types";
import type { EfficiencySort } from "../efficiency";
import { EFFICIENCY_SHORT } from "../metrics";
import { EfficiencyAbout, EfficiencyList } from "./Efficiency";
import { Chip, ProviderBadge, Segmented, useAppStore } from "./primitives";

const VIEW_OPTIONS: { value: ModelsView; label: string }[] = [
  { value: "response", label: "Response speed" },
  { value: "turn", label: "Turn speed" },
  { value: "efficiency", label: EFFICIENCY_SHORT },
];

/**
 * Response speed ranks models across tools; Turn speed keeps one list per measurement group;
 * Efficiency ranks model and effort by the indicator over the last 7 d.
 */
function ViewToggle() {
  const store = useAppStore();
  const view = useStore(store, (s) => s.ui.modelsView);
  return (
    <Segmented
      label="Model speed measurement"
      size="sm"
      value={view}
      options={VIEW_OPTIONS}
      onChange={(v) => store.setModelsView(v)}
    />
  );
}

function ResponseModelRow({
  row,
  selected,
  max,
  onSelect,
  detailed,
}: {
  row: ModelSpeedRow;
  selected: boolean;
  max: number;
  onSelect: () => void;
  detailed: boolean;
}) {
  const fill =
    row.median !== null && max > 0 ? Math.min(100, Math.max(4, (row.median / max) * 100)) : 0;
  const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  const grok = row.tools.includes("grok-build");
  const grokOnly = grok && row.tools.length === 1;
  const sub = row.turns
    ? [
        count(row.turns, "turn", "turns"),
        grokOnly
          ? count(row.responses, "model call", "model calls")
          : count(row.responses, "response", "responses"),
      ].join(" · ")
    : row.untimed
      ? "No per-response timing yet"
      : "Collecting data";
  const title = [
    `${row.model.model ?? "Unknown model"} · ${providerName(row.model.provider)}`,
    `Response speed · median of ${count(row.turns, "turn", "turns")} in 24 h`,
    row.untimed ? `${count(row.untimed, "turn", "turns")} without response timing` : null,
    grok ? `${GROK_RESPONSE_NOTE}\n${GROK_RESPONSE_EXPLANATION}` : null,
  ]
    .filter(Boolean)
    .join("\n");
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
            <ProviderBadge model={row.model.model} provider={row.model.provider} size={16} />
            <span className="model-name-text">{row.model.model ?? "Unknown model"}</span>
            {row.tools.map((id) => (
              <Chip key={id}>{toolLabel(id)}</Chip>
            ))}
            {row.hasSubagent && <Chip title="Includes Subagent work">Subagent</Chip>}
          </span>
          <span className="model-sub">
            {sub}
            {detailed && row.model.provider && row.model.provider !== "unknown" && (
              <> · {providerName(row.model.provider)}</>
            )}
          </span>
        </span>
        <span className="model-value">
          <span className="model-number">
            {num(row.median)}
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
  const fill = median !== null && max > 0 ? Math.min(100, Math.max(4, (median / max) * 100)) : 0;
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
          </span>
          <span className="model-sub">
            {[qualifier, `${stats.throughput.count} ${stats.throughput.count === 1 ? "turn" : "turns"}`]
              .filter(Boolean)
              .join(" · ")}
            {detailed && (
              <>
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

function communityMedians(board: Board | null) {
  const map = new Map<string, number>();
  for (const c of board?.cohorts ?? [])
    if (typeof c.medianThroughput === "number" && c.medianThroughput > 0)
      map.set(c.id, c.medianThroughput);
  return map;
}

function GroupHead({ group }: { group: CohortGroup }) {
  return (
    <h3 className="group-head" title={group.definition}>
      {group.title}
    </h3>
  );
}

export function YourModels({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const view = useStore(store, (s) => s.ui.modelsView);
  if (!dashboard.cohorts.length) return null;
  const rows = sortModelRows(dashboard.modelRows, "speed");
  const max = niceMedianMax(rows);
  const current = dashboard.isAll ? null : dashboard.activeKey;
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
      <div className="view-toggle">
        <ViewToggle />
        {view === "response" && <span className="muted-line">Median over 24 h</span>}
        {view === "efficiency" && <span className="muted-line">Last 7 d</span>}
      </div>
      {view === "efficiency" ? (
        <>
          <EfficiencyAbout badge />
          <EfficiencyList efficiency={dashboard.efficiency} sort="efficiency" flush={false} />
        </>
      ) : view === "response" ? (
        <div className="model-group">
          <ul className="model-list">
            {rows.map((row) => (
              <ResponseModelRow
                key={row.key}
                row={row}
                selected={
                  !!current &&
                  row.key === modelSelection(current)
                }
                max={max}
                detailed={false}
                onSelect={() => void store.selectCohort(row.key)}
              />
            ))}
          </ul>
        </div>
      ) : (
        dashboard.groups.map((group) => (
          <div className="model-group" key={group.key}>
            <GroupHead group={group} />
            <ul className="model-list">
              {group.rows.map((row) => (
                <ModelRow
                  key={row.key}
                  row={row}
                  selected={
                    dashboard.mode.kind !== "all" && dashboard.selectedKey === row.key
                  }
                  max={group.max}
                  detailed={false}
                  community={null}
                  onSelect={() => void store.selectCohort(row.key)}
                />
              ))}
            </ul>
          </div>
        ))
      )}
    </section>
  );
}

const SORTS: { value: SortKey; label: string }[] = [
  { value: "recent", label: "Most recent" },
  { value: "throughput", label: "Higher turn speed" },
  { value: "ttft", label: "Lower first token" },
];
const RESPONSE_SORTS: { value: ModelSort; label: string }[] = [
  { value: "speed", label: "Higher response speed" },
  { value: "recent", label: "Most recent" },
];
const EFFICIENCY_SORTS: { value: EfficiencySort; label: string }[] = [
  { value: "efficiency", label: "Higher efficiency" },
  { value: "recent", label: "Most recent" },
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
  const view = useStore(store, (s) => s.ui.modelsView);
  const groups = dashboard.compareGroups;
  const community = communityMedians(board);
  const dayLabel = dashboard.days === 1 ? "24 h" : "7 d";
  const responseSort: ModelSort = sort === "recent" ? "recent" : "speed";
  const responseRows = sortModelRows(dashboard.modelRows, responseSort);
  const responseMax = niceMedianMax(responseRows);
  const efficiencySort: EfficiencySort = sort === "recent" ? "recent" : "efficiency";
  return (
    <section className="card compare" aria-labelledby="compare-title">
      <div className="section-head">
        <h1 id="compare-title">All models</h1>
        <label className="sort">
          <span className="visually-hidden">Sort models by</span>
          {view === "response" || view === "efficiency" ? (
            <select
              value={view === "efficiency" ? efficiencySort : responseSort}
              onChange={(e) => store.setSort(e.target.value === "recent" ? "recent" : "throughput")}
            >
              {(view === "efficiency" ? EFFICIENCY_SORTS : RESPONSE_SORTS).map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
          ) : (
            <select value={sort} onChange={(e) => store.setSort(e.target.value as SortKey)}>
              {SORTS.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
          )}
        </label>
      </div>
      <div className="view-toggle">
        <ViewToggle />
      </div>
      <p className="muted-line">
        {view === "response"
          ? "Median response speed over the last 24 h."
          : view === "efficiency"
            ? "Efficiency indicator over your last 7 d, whatever the chart range."
            : `Median turn speed over the last ${dayLabel}.`}
      </p>
      {view === "efficiency" && <EfficiencyAbout badge />}
      {view === "efficiency" ? (
        <EfficiencyList efficiency={dashboard.efficiency} sort={efficiencySort} flush />
      ) : view === "response" ? (
        responseRows.length ? (
          <div className="model-group">
            <ul className="model-list model-list-flush">
              {responseRows.map((row) => (
                <ResponseModelRow
                  key={row.key}
                  row={row}
                  selected={false}
                  max={responseMax}
                  detailed
                  onSelect={() => void store.selectCohort(row.key)}
                />
              ))}
            </ul>
          </div>
        ) : (
          <p className="empty">Complete a supported coding-tool response to compare models.</p>
        )
      ) : groups.length ? (
        groups.map((group) => (
          <div className="model-group" key={group.key}>
            <GroupHead group={group} />
            <ul className="model-list model-list-flush">
              {group.rows.map((row) => (
                <ModelRow
                  key={row.key}
                  row={row}
                  selected={false}
                  max={group.max}
                  detailed
                  community={community.get(communityId(row.sample)) ?? null}
                  onSelect={() => void store.selectCohort(row.key)}
                />
              ))}
            </ul>
          </div>
        ))
      ) : (
        <p className="empty">Complete a supported coding-tool turn to compare models.</p>
      )}
      <p className="fine">
        {view === "efficiency"
          ? "Each model and reasoning effort counts every coding tool, provider and version. Requests under 200 tokens are left out, and each group needs 20 eligible requests. It depends on what you ask each model to do, and this is not an answer-quality ranking."
          : view === "response"
          ? "Response speed pools each model's responses across coding tools and Subagent work. Grok Build records output per turn, so its value is an average over all model calls in a turn (hover a row for details). Different workloads affect these numbers, and this is not an answer-quality ranking."
          : "Different workloads and measurement definitions affect these numbers. Subagent, Work-turn and whole-turn speeds are never ranked against each other, and this is not an answer-quality ranking."}
      </p>
      <button type="button" className="text-button back" onClick={() => void store.selectCohort("auto")}>
        <ArrowLeft size={16} aria-hidden="true" />
        Back to Auto
      </button>
    </section>
  );
}
