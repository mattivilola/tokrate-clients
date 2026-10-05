import { Mark, useAppStore, Chip } from "./primitives";
import { ModelPicker } from "./Header";
import { Footer } from "./Footer";
import { chartCopy, MetricToggle, RangeToggle, TrendDetails, useTrendBuckets } from "./Trend";
import { TrendChart } from "./TrendChart";
import {
  clientLabel,
  measurementChip,
  measurementTitle,
  providerRoute,
  relativeTime,
  responseSpeed,
} from "../metrics";
import type { Dashboard } from "../model/dashboard";
import { effortChip, exactTime, modelName, num } from "../model/format";
import { useStore } from "../store/store";

const MAX_ROWS = 500;

/** The full-history window: larger chart, the numbers behind it and the bounded 500-row table. */
export function HistoryView({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const metric = useStore(store, (s) => s.ui.chartMetric);
  const copy = chartCopy(dashboard, metric);
  const data = useTrendBuckets(dashboard, copy.metric);
  const rows = dashboard.historyRows.slice(0, MAX_ROWS);
  const dayLabel = dashboard.days === 1 ? "24 hours" : "7 days";
  return (
    <div className="history-view">
      <header className="topbar history-topbar">
        <div className="brand">
          <Mark size={28} />
          <span>Tokrate history</span>
        </div>
        <ModelPicker dashboard={dashboard} />
        <RangeToggle />
      </header>
      <div className="scroll history-scroll">
        {dashboard.isAll ? (
          <section className="card" aria-label="Trend">
            <h2>All models</h2>
            <p className="hint">
              Choose one model above to see its trend, ranges and baseline. Comparing all models
              never pools their speeds; the table below lists every turn with its response speed
              and turn speed.
            </p>
          </section>
        ) : (
          <div className="history-grid">
            <section className="card trend history-chart" aria-label="Trend">
              <div className="card-head">
                <h2>
                  {modelName(dashboard.sample)} · last {dayLabel}
                </h2>
                <MetricToggle dashboard={dashboard} />
              </div>
              <TrendChart
                buckets={data}
                unit={copy.unit}
                days={dashboard.days}
                height={260}
                emptyMessage={copy.empty}
                ariaLabel={`${copy.title} over the last ${dayLabel}`}
              />
            </section>
            <section className="card history-details" aria-label="Details">
              <h2>Details</h2>
              <TrendDetails dashboard={dashboard} />
            </section>
          </div>
        )}
        <section className="card history-table-card" aria-labelledby="turn-history">
          <h2 id="turn-history">
            Turn history <span className="muted-count">({rows.length} shown, newest first)</span>
          </h2>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th scope="col">Completed</th>
                  <th scope="col">Coding tool and model</th>
                  <th scope="col" className="num">Tokens</th>
                  <th scope="col" className="num">Response speed</th>
                  <th scope="col" className="num">Turn speed</th>
                  <th scope="col" className="num">First token</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((m) => (
                  <tr key={m.id}>
                    <td>
                      <time dateTime={m.completedAt} title={exactTime(m.completedAt)}>
                        {relativeTime(Date.parse(m.completedAt), dashboard.now)}
                      </time>
                    </td>
                    <td>
                      <span className="table-model">
                        <strong>{modelName(m)}</strong>
                        <Chip>{effortChip(m)}</Chip>
                        {measurementChip(m) && <Chip>{measurementChip(m)}</Chip>}
                      </span>
                      <span className="table-sub">
                        {clientLabel(m)} · {providerRoute(m.provider)}
                      </span>
                    </td>
                    <td className="num">{m.outputTokens}</td>
                    <td className="num">
                      {responseSpeed(m) === null ? (
                        "—"
                      ) : (
                        <>
                          <strong>{num(responseSpeed(m))}</strong> tok/s
                          <span className="table-sub">
                            {m.responseCount ?? 0} {m.responseCount === 1 ? "response" : "responses"}
                          </span>
                        </>
                      )}
                    </td>
                    <td className="num">
                      <strong>{num(m.turnThroughputTPS)}</strong> tok/s
                      <span className="table-sub">{measurementTitle(m)}</span>
                    </td>
                    <td className="num">
                      {m.codexTTFTSeconds === null ? "—" : `${num(m.codexTTFTSeconds)} s`}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!rows.length && <p className="empty">Collecting data</p>}
          </div>
        </section>
      </div>
      <Footer />
    </div>
  );
}
