import { useMemo } from "react";
import { buckets, client, measurementLabel, type Metric } from "../metrics";
import type { Dashboard } from "../model/dashboard";
import { num, signedPercent } from "../model/format";
import { useStore } from "../store/store";
import type { ChartMetric } from "../store/types";
import { Disclosure, Segmented, useAppStore } from "./primitives";
import { TrendChart } from "./TrendChart";

/** First-token time exists only for Codex; other tools stay separate and say so. */
export const supportsFirstToken = (sample: Metric | undefined) =>
  !sample || client(sample) === "codex";

export function useTrendBuckets(
  dashboard: Dashboard,
  metric: ChartMetric,
  source: Metric[] = dashboard.inRange,
) {
  return useMemo(
    () => buckets(source, dashboard.now, dashboard.days, metric),
    [source, dashboard.now, dashboard.days, metric],
  );
}

export function MetricToggle({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const metric = useStore(store, (s) => s.ui.chartMetric);
  const firstToken = supportsFirstToken(dashboard.sample);
  return (
    <Segmented
      label="Chart metric"
      size="sm"
      value={firstToken ? metric : "throughput"}
      onChange={(v) => store.setChartMetric(v)}
      options={[
        { value: "throughput", label: "Turn speed" },
        {
          value: "ttft",
          label: "First token",
          disabled: !firstToken,
          title: firstToken
            ? undefined
            : "First-token time is not captured for this coding tool",
        },
      ]}
    />
  );
}

export function RangeToggle() {
  const store = useAppStore();
  const days = useStore(store, (s) => s.snapshot.settings.days);
  return (
    <Segmented
      label="History range"
      size="sm"
      value={String(days) as "1" | "7"}
      onChange={(v) => void store.setDays(v === "1" ? 1 : 7)}
      options={[
        { value: "1", label: "24 h" },
        { value: "7", label: "7 d" },
      ]}
    />
  );
}

export function chartCopy(dashboard: Dashboard, metric: ChartMetric) {
  const firstToken = supportsFirstToken(dashboard.sample);
  const effective: ChartMetric = firstToken ? metric : "throughput";
  return {
    metric: effective,
    unit: effective === "throughput" ? "tok/s" : "s",
    title: effective === "throughput" ? "Turn speed" : "First token",
    empty:
      effective === "throughput"
        ? "Collecting data"
        : "No first-token times in this range",
    summary:
      effective === "throughput"
        ? dashboard.summary.throughput
        : dashboard.summary.ttft,
  };
}

export function Trend({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const metric = useStore(store, (s) => s.ui.chartMetric);
  const copy = chartCopy(dashboard, metric);
  const data = useTrendBuckets(dashboard, copy.metric);
  const { summary } = copy;
  const dayLabel = dashboard.days === 1 ? "24 h" : "7 d";
  // No evidence at all collapses to one status line instead of an empty chart.
  if (!dashboard.sample)
    return (
      <section className="card status-card" aria-label="Trend">
        <p>Collecting data</p>
      </section>
    );
  return (
    <section className="card trend" aria-label="Trend">
      <div className="card-head">
        <MetricToggle dashboard={dashboard} />
        <RangeToggle />
      </div>
      <TrendChart
        buckets={data}
        unit={copy.unit}
        days={dashboard.days}
        height={112}
        emptyMessage={copy.empty}
        ariaLabel={`${copy.title} over the last ${dayLabel}`}
      />
      <p className="trend-foot">
        {summary.count ? (
          <>
            Median <strong>{num(summary.median)}</strong> {copy.unit} · {summary.count}{" "}
            {summary.count === 1 ? "turn" : "turns"} in {dayLabel}
          </>
        ) : (
          <>Collecting data</>
        )}
      </p>
      <Disclosure label="Details" className="trend-details">
        <TrendDetails dashboard={dashboard} />
      </Disclosure>
    </section>
  );
}

function StatRow({
  label,
  median,
  min,
  max,
  count,
  unit,
}: {
  label: string;
  median: number | null;
  min: number | null;
  max: number | null;
  count: number;
  unit: string;
}) {
  return (
    <div className="stat-row">
      <dt>{label}</dt>
      <dd>
        <strong>
          {num(median)} {unit}
        </strong>
        <span>
          min {num(min)} · max {num(max)} · {count} {count === 1 ? "turn" : "turns"}
        </span>
      </dd>
    </div>
  );
}

/** The numbers behind the headline: ranges, recent window, period change and baseline signals. */
export function TrendDetails({ dashboard }: { dashboard: Dashboard }) {
  const { summary, recent15m, change, signals, sample } = dashboard;
  const dayLabel = dashboard.days === 1 ? "24 h" : "7 d";
  const firstToken = supportsFirstToken(sample);
  const pct = (v: number | null) => (v === null ? "—" : signedPercent(v));
  return (
    <div className="details">
      <dl className="stats">
        <StatRow
          label={`Turn speed · ${dayLabel}`}
          unit="tok/s"
          {...summary.throughput}
        />
        {firstToken ? (
          <StatRow label={`First token · ${dayLabel}`} unit="s" {...summary.ttft} />
        ) : (
          <div className="stat-row">
            <dt>First token</dt>
            <dd>
              <span>Not captured for this coding tool</span>
            </dd>
          </div>
        )}
        <StatRow
          label="Last 15 minutes"
          unit="tok/s"
          {...recent15m.throughput}
        />
      </dl>
      <p className="detail-line">
        <strong>24 h vs previous 24 h</strong>
        <span>
          Turn speed {pct(change.throughput)}
          {firstToken && <> · First token {pct(change.ttft)}</>}
        </span>
        <small>Needs 5 turns in each period.</small>
      </p>
      <p className="detail-line">
        <strong>Your baseline</strong>
        <span>{signals.throughput}</span>
        {firstToken && <span>{signals.ttft}</span>}
        <small>Your workload may have changed.</small>
      </p>
      <p className="detail-line detail-fine">
        {sample ? measurementLabel(sample) : "Turn speed"}.
        {firstToken && " First token is the wait Codex reports and does not claim first visible text."}{" "}
        Bucket medians, gaps mean no turns. Different workloads and measurement definitions affect
        these numbers; this is not an answer-quality ranking.
      </p>
    </div>
  );
}
