import { useMemo } from "react";
import {
  GROK_RESPONSE_EXPLANATION,
  buckets,
  client,
  isGrokBuild,
  measurementLabel,
  toolLabel,
  type Metric,
} from "../metrics";
import type { Dashboard } from "../model/dashboard";
import { num, signedPercent } from "../model/format";
import { useStore } from "../store/store";
import type { ChartMetric } from "../store/types";
import { Disclosure, Segmented, useAppStore } from "./primitives";
import { TrendChart } from "./TrendChart";

/** First-token time exists only for Codex; other tools stay separate and say so. */
export const supportsFirstToken = (sample: Metric | undefined) =>
  !sample || client(sample) === "codex";

/** Response speed pools the model's turns across tools; turn speed and first token stay on one cohort. */
export function useTrendBuckets(
  dashboard: Dashboard,
  metric: ChartMetric,
  source: Metric[] = metric === "response" ? dashboard.responseInRange : dashboard.inRange,
) {
  return useMemo(
    () => buckets(source, dashboard.now, dashboard.days, metric),
    [source, dashboard.now, dashboard.days, metric],
  );
}

const SPEED_HELP = "Response speed excludes tools and your time; turn speed covers the whole turn.";

export function MetricToggle({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const metric = useStore(store, (s) => s.ui.chartMetric);
  const firstToken = supportsFirstToken(dashboard.sample);
  return (
    <Segmented
      label="Chart metric"
      size="sm"
      value={chartCopy(dashboard, metric).metric}
      onChange={(v) => store.setChartMetric(v)}
      options={[
        { value: "response", label: "Response speed", title: SPEED_HELP },
        { value: "throughput", label: "Turn speed", title: SPEED_HELP },
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

/** The selected model has turns but none with per-response timing (for example Grok Build). */
export const responseSpeedUnavailable = (dashboard: Dashboard) =>
  !!dashboard.sample && dashboard.hero.value === null && dashboard.responseTotals.turns === 0;

/** Why there is no response speed: names the coding tool when its source records only whole turns. */
export const responseUnavailableText = (sample: Metric | undefined) =>
  sample && client(sample) === "grok-build"
    ? `No response speed for these ${toolLabel("grok-build")} turns: they were recorded before Tokrate 0.1.15.`
    : "No response speed for this model yet.";

/**
 * Chart copy for the chosen metric. `null` is automatic: Response, or Turn when the model has no
 * response data. An explicit choice is never overridden, even when it has no data.
 */
export function chartCopy(dashboard: Dashboard, metric: ChartMetric | null) {
  const firstToken = supportsFirstToken(dashboard.sample);
  const unavailable = responseSpeedUnavailable(dashboard);
  const effective: ChartMetric =
    metric && (firstToken || metric !== "ttft")
      ? metric
      : unavailable
        ? "throughput"
        : "response";
  return {
    metric: effective,
    unit: effective === "ttft" ? "s" : "tok/s",
    title: { response: "Response speed", throughput: "Turn speed", ttft: "First token" }[effective],
    empty:
      effective === "ttft"
        ? "No first-token times in this range"
        : effective === "response" && unavailable
          ? responseUnavailableText(dashboard.sample)
          : "Collecting data",
    summary: {
      response: dashboard.responseSummary,
      throughput: dashboard.summary.throughput,
      ttft: dashboard.summary.ttft,
    }[effective],
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
            {copy.metric === "response" && dashboard.responseTotals.responses > 0 && (
              <>
                {" "}
                · {dashboard.responseTotals.responses}{" "}
                {dashboard.responseTotals.responses === 1 ? "response" : "responses"}
              </>
            )}
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
          label={`Response speed · ${dayLabel}`}
          unit="tok/s"
          {...dashboard.responseSummary}
        />
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
          label="Last 15 minutes · response speed"
          unit="tok/s"
          {...dashboard.recentResponse15m}
        />
        <StatRow
          label="Last 15 minutes · turn speed"
          unit="tok/s"
          {...recent15m.throughput}
        />
      </dl>
      <p className="detail-line">
        <strong>24 h vs previous 24 h</strong>
        <span>
          Response speed {pct(change.response)} · Turn speed {pct(change.throughput)}
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
        Response speed pools this model&apos;s responses across coding tools.
        {isGrokBuild(sample) && ` ${GROK_RESPONSE_EXPLANATION}`} Turn speed:{" "}
        {sample ? measurementLabel(sample) : "Turn speed"}.
        {firstToken && " First token is the wait Codex reports and does not claim first visible text."}{" "}
        Bucket medians, gaps mean no turns. Different workloads and measurement definitions affect
        these numbers; this is not an answer-quality ranking.
      </p>
    </div>
  );
}
