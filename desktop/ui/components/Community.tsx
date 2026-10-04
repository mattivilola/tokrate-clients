import { Users } from "lucide-react";
import { alertsForCohorts } from "../metrics";
import {
  communityLine,
  communityRows,
  communityWindowLabel,
  type Dashboard,
} from "../model/dashboard";
import { exactTime, num } from "../model/format";
import { useStore } from "../store/store";
import { Chip, Disclosure, useAppStore } from "./primitives";

/** One line about the community, shown only while sharing is on; the details sit behind a disclosure. */
export function Community({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const settings = useStore(store, (s) => s.snapshot.settings);
  const board = useStore(store, (s) => s.snapshot.board);
  const status = useStore(store, (s) => s.snapshot.status);
  const toolFilter = useStore(store, (s) => s.ui.toolFilter);
  const providerFilter = useStore(store, (s) => s.ui.providerFilter);
  if (!settings.sharing) return null;

  const line = dashboard.isAll ? null : communityLine(board, dashboard);
  const rows = communityRows(board, dashboard, toolFilter, providerFilter);
  const alerts = alertsForCohorts(
    board?.alerts ?? [],
    new Set(rows.map((c) => c.id)),
  );
  const summary = dashboard.isAll
    ? board
      ? `${rows.length} ${rows.length === 1 ? "model" : "models"} published by the community`
      : status
    : line
      ? null
      : board
        ? "No community data for this model yet"
        : status;

  return (
    <section className="card community" aria-label="Community">
      <div className="community-line">
        <Users size={18} aria-hidden="true" className="community-icon" />
        {line ? (
          <p>
            <span>
              Community median <strong>{num(line.median, 0)}</strong> tok/s ·{" "}
              {line.windowLabel}
            </span>
            {line.position !== null && (
              <span className="community-position">
                {line.position === 0
                  ? "You're right at the median"
                  : `You're ${Math.abs(line.position)}% ${line.position > 0 ? "faster" : "slower"}`}
              </span>
            )}
          </p>
        ) : (
          <p>{summary}</p>
        )}
        {(line?.caution ?? (board?.methodology?.publicationMode === "early_data" ? "Early data" : null)) && (
          <Chip tone="warn" title="Published from a small number of contributors">
            {line?.caution ?? "Early data"}
          </Chip>
        )}
      </div>
      <Disclosure label="Community details">
        <div className="details">
          {board ? (
            <p className="detail-fine">
              Window {communityWindowLabel(board.window)} · Processing: {board.state ?? "unknown"} ·
              Observations through {exactTime(board.dataAsOf ?? "")}
            </p>
          ) : (
            <p className="detail-fine">{status}</p>
          )}
          {rows.map((c) => (
            <div className="community-row" key={c.id}>
              <div>
                <strong>{c.model ?? "Unknown model"}</strong>
                <span>
                  {c.reasoningEffort ?? "unknown"} effort · {c.contributors ?? 0} contributors ·{" "}
                  {c.throughputTurns ?? c.turns ?? 0} turns
                  {c.ttftTurns ? ` · ${c.ttftTurns} with first token` : ""}
                </span>
                <span>
                  Turn speed: {c.signals?.throughput?.state ?? "collecting data"}
                  {c.ttftTurns ? ` · First token: ${c.signals?.ttft?.state ?? "collecting data"}` : ""}
                </span>
              </div>
              <div className="community-numbers">
                <strong>{num(c.medianThroughput)} tok/s</strong>
                {typeof c.medianTtftMs === "number" && (
                  <span>{num(c.medianTtftMs / 1000)} s first token</span>
                )}
              </div>
            </div>
          ))}
          {!rows.length && board && (
            <p className="detail-fine">
              No published observations for this exact model and effort.
            </p>
          )}
          {alerts.map((a, i) => (
            <p className="detail-line" key={i}>
              {a.message ?? `${a.metric ?? "Performance"}: ${a.state ?? "change observed"}`}
            </p>
          ))}
          <p className="detail-fine">
            Missing alerts do not establish provider health. Geography, Fast mode
            and answer quality are not measured. Data refreshes at most every 30
            seconds while sharing is on.
          </p>
        </div>
      </Disclosure>
    </section>
  );
}
