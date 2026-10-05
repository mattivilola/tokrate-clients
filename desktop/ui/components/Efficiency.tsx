import { useId, useState } from "react";
import { ChevronDown } from "lucide-react";
import {
  EFFICIENCY_MIN_TURNS,
  efficiencyScaleMax,
  sortEfficiencyRows,
  type EfficiencyDashboard,
  type EfficiencyRow,
  type EfficiencySort,
} from "../efficiency";
import {
  EFFICIENCY_DEFINITION,
  EFFICIENCY_EXPLANATION,
  EFFICIENCY_INSUFFICIENT,
} from "../metrics";
import { compactTokens, effortText, percentText } from "../model/format";
import { Chip, InfoDisclosure, ProviderBadge } from "./primitives";

/** "n of 20 requests" for a group that has not reached the floor yet. */
export const requestsOfFloor = (turns: number) => `${turns} of ${EFFICIENCY_MIN_TURNS} requests`;
const requestCount = (n: number) => `${n} ${n === 1 ? "request" : "requests"}`;

/** The one-line definition, its ⓘ explanation and, in lists, the "Indicator" badge. */
export function EfficiencyAbout({ badge = false }: { badge?: boolean }) {
  return (
    <div className="eff-about">
      {badge && <Chip tone="accent">Indicator</Chip>}
      <span className="eff-about-text">{EFFICIENCY_DEFINITION}</span>
      <InfoDisclosure label="About the efficiency indicator">{EFFICIENCY_EXPLANATION}</InfoDisclosure>
    </div>
  );
}

/** The statistics behind one group's indicator, as `.stat-row`s for a `.stats` list. */
export function EfficiencyDetailRows({ row }: { row: EfficiencyRow }) {
  return (
    <>
      <div className="stat-row">
        <dt>Eligible requests</dt>
        <dd>
          <strong>{row.turns}</strong>
          <span>7 d · 200 tokens or more</span>
        </dd>
      </div>
      <div className="stat-row">
        <dt>Median tokens/request</dt>
        <dd>
          <strong>{compactTokens(row.medianTokens)}</strong>
          <span>
            middle half {compactTokens(row.p25Tokens)}–{compactTokens(row.p75Tokens)}
          </span>
        </dd>
      </div>
      <div className="stat-row">
        <dt>Reasoning share</dt>
        <dd>
          <strong>{percentText(row.reasoningShare)}</strong>
          <span>median of output tokens</span>
        </dd>
      </div>
      <div className="stat-row">
        <dt>Delegated share</dt>
        <dd>
          <strong>{percentText(row.delegatedShare)}</strong>
          <span>of all tokens, subagent work</span>
        </dd>
      </div>
    </>
  );
}

function EfficiencyListRow({
  row,
  scaleMax,
}: {
  row: EfficiencyRow;
  scaleMax: number;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const fill =
    row.indicator === null ? 0 : Math.min(100, Math.max(4, (row.indicator / scaleMax) * 100));
  const sub =
    row.indicator === null
      ? "Not enough requests yet"
      : `${compactTokens(row.medianTokens)} tokens/request · ${requestCount(row.turns)}`;
  return (
    <li>
      <button
        type="button"
        className="model-row eff-row"
        aria-expanded={open}
        aria-controls={id}
        title={`${row.model} · ${effortText(row.effort)}\nEfficiency indicator · 100 = a typical request`}
        onClick={() => setOpen(!open)}
      >
        <span className="model-main">
          <span className="model-name">
            <ProviderBadge model={row.model} provider={row.provider} size={16} />
            <span className="model-name-text">{row.model}</span>
            <Chip tone={row.effort === "unknown" ? "neutral" : "accent"}>{effortText(row.effort)}</Chip>
          </span>
          <span className="model-sub">{sub}</span>
        </span>
        <span className="model-value">
          {row.indicator === null ? (
            <span className="model-sub">{requestsOfFloor(row.turns)}</span>
          ) : (
            <span className="model-number">
              {row.indicator}
              <small> indicator</small>
            </span>
          )}
        </span>
        <ChevronDown size={16} aria-hidden="true" className="chevron" />
        {row.indicator !== null && (
          <span className="eff-bar" aria-hidden="true">
            <span className="eff-bar-fill" style={{ width: `${fill}%` }} />
            <span className="eff-bar-tick" style={{ left: `${(100 / scaleMax) * 100}%` }} />
          </span>
        )}
      </button>
      {open && (
        <div className="eff-detail" id={id}>
          <dl className="stats">
            <EfficiencyDetailRows row={row} />
          </dl>
        </div>
      )}
    </li>
  );
}

/**
 * Models ranked by efficiency indicator, highest first. Bars share one scale with a tick at 100
 * ("typical"); groups under 20 requests show their progress instead of a value.
 */
export function EfficiencyList({
  efficiency,
  sort,
  flush,
}: {
  efficiency: EfficiencyDashboard;
  sort: EfficiencySort;
  flush: boolean;
}) {
  const rows = sortEfficiencyRows(efficiency.rows, sort);
  if (!rows.length) return <p className="empty">{EFFICIENCY_INSUFFICIENT}</p>;
  const scaleMax = efficiencyScaleMax(rows);
  const tick = (100 / scaleMax) * 100;
  return (
    <div className="model-group">
      {!efficiency.reference && <p className="muted-line eff-note">{EFFICIENCY_INSUFFICIENT}</p>}
      {efficiency.reference && (
        <div className="eff-scale" aria-hidden="true">
          <span className={tick > 85 ? "eff-scale-end" : undefined} style={{ left: `${tick}%` }}>
            typical
          </span>
        </div>
      )}
      <ul className={flush ? "model-list model-list-flush" : "model-list"}>
        {rows.map((row) => (
          <EfficiencyListRow key={row.key} row={row} scaleMax={scaleMax} />
        ))}
      </ul>
    </div>
  );
}
