import {
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent,
} from "react";
import { num, shortTime } from "../model/format";

export interface TrendBucket {
  at: number;
  end: number;
  value: number | null;
  min: number | null;
  max: number | null;
  count: number;
}

/** Smallest "nice" number (1, 2, 2.5, 5 x 10^k) at or above the value. */
export function niceCeil(value: number): number {
  if (!(value > 0)) return 1;
  const exponent = Math.floor(Math.log10(value));
  const base = 10 ** exponent;
  for (const step of [1, 2, 2.5, 5, 10]) {
    if (step * base >= value * 0.999) return step * base;
  }
  return 10 * base;
}

function useWidth<T extends HTMLElement>(fallback: number) {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(fallback);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setWidth(Math.max(120, Math.round(el.clientWidth)));
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return [ref, width] as const;
}

const MARGIN = { top: 10, right: 8, bottom: 22, left: 34 };

/**
 * One chart for the flyout (compact) and the history window (large): gradient line, min-max band,
 * gaps for missing buckets, a dot for an isolated bucket, three gridlines and a keyboard-reachable
 * crosshair with a time, value and turns tooltip.
 */
export function TrendChart({
  buckets,
  unit,
  days,
  height,
  emptyMessage,
  ariaLabel,
  digits = 1,
  noun = "turn",
}: {
  buckets: TrendBucket[];
  /** Appended to tooltip values; empty for the unitless efficiency indicator. */
  unit: string;
  days: number;
  height: number;
  emptyMessage: string;
  ariaLabel: string;
  /** Decimals of the tooltip value. */
  digits?: number;
  /** What one observation is called in the tooltip ("turn", "request"). */
  noun?: string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>(348);
  const gradient = useId();
  const [active, setActive] = useState<number | null>(null);
  const populated = useMemo(
    () => buckets.flatMap((b, i) => (b.value === null ? [] : [i])),
    [buckets],
  );
  const top = useMemo(
    () =>
      niceCeil(
        Math.max(1, ...buckets.map((b) => b.max ?? b.value ?? 0)) * 1.04,
      ),
    [buckets],
  );
  const plotWidth = width - MARGIN.left - MARGIN.right;
  const plotHeight = height - MARGIN.top - MARGIN.bottom;
  const x = (i: number) =>
    MARGIN.left +
    (buckets.length > 1 ? (i * plotWidth) / (buckets.length - 1) : 0);
  const y = (v: number) => MARGIN.top + plotHeight - (v / top) * plotHeight;

  // Continuous runs of populated buckets; a gap ends a run.
  const runs = useMemo(() => {
    const result: number[][] = [];
    let run: number[] = [];
    buckets.forEach((b, i) => {
      if (b.value === null) {
        if (run.length) result.push(run);
        run = [];
      } else run.push(i);
    });
    if (run.length) result.push(run);
    return result;
  }, [buckets]);

  const nearest = (clientX: number, rect: DOMRect) => {
    if (!populated.length) return null;
    const px = clientX - rect.left;
    let best = populated[0];
    for (const i of populated)
      if (Math.abs(x(i) - px) < Math.abs(x(best) - px)) best = i;
    return best;
  };
  const onPointerMove = (event: PointerEvent<HTMLDivElement>) =>
    setActive(nearest(event.clientX, event.currentTarget.getBoundingClientRect()));
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!populated.length) return;
    const at = active === null ? -1 : populated.indexOf(active);
    let next: number | null = null;
    if (event.key === "ArrowRight") next = populated[Math.min(populated.length - 1, at + 1)];
    else if (event.key === "ArrowLeft")
      next = populated[Math.max(0, at < 0 ? populated.length - 1 : at - 1)];
    else if (event.key === "Home") next = populated[0];
    else if (event.key === "End") next = populated[populated.length - 1];
    else if (event.key === "Escape" && active !== null) {
      event.stopPropagation();
      setActive(null);
      return;
    }
    if (next !== null) {
      event.preventDefault();
      setActive(next);
    }
  };

  const point = active === null ? null : buckets[active];
  const pointText =
    point && point.value !== null
      ? `${shortTime(point.at)} · ${[num(point.value, digits), unit].filter(Boolean).join(" ")} · ${point.count} ${point.count === 1 ? noun : `${noun}s`}`
      : "";
  const labels =
    days === 1
      ? ["24 h ago", "12 h ago", "Now"]
      : ["7 d ago", "3.5 d ago", "Now"];
  const gridValues = [0, top / 2, top];

  return (
    <div
      ref={ref}
      className="trend-chart"
      style={{ height }}
      tabIndex={0}
      role="group"
      aria-label={`${ariaLabel}. Missing observations are gaps. Use arrow keys to inspect values.`}
      onPointerMove={onPointerMove}
      onPointerLeave={() => setActive(null)}
      onKeyDown={onKeyDown}
      onBlur={() => setActive(null)}
    >
      <svg width={width} height={height} aria-hidden="true">
        <defs>
          <linearGradient
            id={gradient}
            gradientUnits="userSpaceOnUse"
            x1={MARGIN.left}
            x2={width - MARGIN.right}
            y1="0"
            y2="0"
          >
            <stop offset="0" style={{ stopColor: "var(--arc-start)" }} />
            <stop offset="1" style={{ stopColor: "var(--arc-end)" }} />
          </linearGradient>
        </defs>
        {gridValues.map((v) => (
          <g key={v}>
            <line
              className="grid-line"
              x1={MARGIN.left}
              x2={width - MARGIN.right}
              y1={y(v)}
              y2={y(v)}
            />
            <text className="axis-label" x={MARGIN.left - 6} y={y(v) + 4} textAnchor="end">
              {num(v, top < 10 ? 1 : 0)}
            </text>
          </g>
        ))}
        {runs.map((run) =>
          run.length > 1 ? (
            <g key={run[0]}>
              <path
                className="band"
                d={
                  run.map((i, n) => `${n ? "L" : "M"}${x(i)},${y(buckets[i].min ?? 0)}`).join("") +
                  [...run]
                    .reverse()
                    .map((i) => `L${x(i)},${y(buckets[i].max ?? 0)}`)
                    .join("") +
                  "Z"
                }
              />
              <path
                className="trend-line"
                fill="none"
                stroke={`url(#${gradient})`}
                d={run
                  .map((i, n) => `${n ? "L" : "M"}${x(i)},${y(buckets[i].value ?? 0)}`)
                  .join("")}
              />
            </g>
          ) : (
            <circle
              key={run[0]}
              className="trend-dot"
              cx={x(run[0])}
              cy={y(buckets[run[0]].value ?? 0)}
              r="3.5"
            />
          ),
        )}
        {labels.map((label, i) => (
          <text
            key={label}
            className="axis-label"
            x={MARGIN.left + (i * plotWidth) / 2}
            y={height - 5}
            textAnchor={i === 0 ? "start" : i === 2 ? "end" : "middle"}
          >
            {label}
          </text>
        ))}
        {point && point.value !== null && active !== null && (
          <g>
            <line
              className="crosshair"
              x1={x(active)}
              x2={x(active)}
              y1={MARGIN.top}
              y2={MARGIN.top + plotHeight}
            />
            <circle className="crosshair-dot" cx={x(active)} cy={y(point.value)} r="4.5" />
          </g>
        )}
      </svg>
      {!populated.length && <p className="chart-empty">{emptyMessage}</p>}
      {point && point.value !== null && active !== null && (
        <div
          className="chart-tooltip"
          style={{
            left: Math.min(Math.max(x(active), 100), width - 100),
            top: Math.max(0, y(point.value) - 44),
          }}
        >
          {pointText}
        </div>
      )}
      <span className="visually-hidden" aria-live="polite">
        {pointText}
      </span>
    </div>
  );
}
