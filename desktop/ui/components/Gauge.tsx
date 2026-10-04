import { useId } from "react";
import { readout } from "../model/format";

const CX = 120;
const CY = 100;
const R = 88;
const START = 150;
const SWEEP = 240;
const rad = (deg: number) => (deg * Math.PI) / 180;
const point = (deg: number, r = R) => ({
  x: CX + r * Math.cos(rad(deg)),
  y: CY + r * Math.sin(rad(deg)),
});

/**
 * Geometry shared with the tests: the hub is the arc centre, the needle is radius - 14 long and the
 * readout sits below the lowest point the needle (150 or 30 degrees) and hub can reach.
 */
export const GAUGE = {
  cx: CX,
  cy: CY,
  radius: R,
  needleLength: R - 14,
  hubRadius: 6,
  readoutTop: 144,
  valueBaseline: 178,
  unitBaseline: 198,
} as const;

/** 240 degree dial from 150 degrees to 30 degrees; static, with one eased change transition. */
export function Gauge({
  value,
  max,
  caption,
  label,
}: {
  value: number | null;
  /** Nice scale ceiling from the value's measurement group. */
  max: number;
  /** One-line context shown under the dial (empty state or definition). */
  caption?: string;
  /** Accessible description of the reading. */
  label: string;
}) {
  const gradient = useId();
  const fraction = value === null ? 0 : Math.min(1, Math.max(0, value / max));
  const start = point(START);
  const end = point(START + SWEEP);
  const arc = `M${start.x.toFixed(2)} ${start.y.toFixed(2)}A${R} ${R} 0 1 1 ${end.x.toFixed(2)} ${end.y.toFixed(2)}`;
  const tip = point(START, GAUGE.needleLength);
  const text = readout(value);
  return (
    <figure className="gauge">
      <svg viewBox="0 0 240 206" role="img" aria-label={label}>
        <defs>
          <linearGradient
            id={gradient}
            gradientUnits="userSpaceOnUse"
            x1={start.x}
            x2={end.x}
            y1="0"
            y2="0"
          >
            <stop offset="0" style={{ stopColor: "var(--arc-start)" }} />
            <stop offset="1" style={{ stopColor: "var(--arc-end)" }} />
          </linearGradient>
        </defs>
        <path
          className="gauge-track"
          d={arc}
          pathLength={1}
          fill="none"
          strokeWidth="12"
          strokeLinecap="round"
        />
        <path
          className="gauge-arc"
          d={arc}
          pathLength={1}
          fill="none"
          stroke={`url(#${gradient})`}
          strokeWidth="12"
          strokeLinecap="round"
          strokeDasharray={`${fraction} 1`}
          style={{ opacity: value === null ? 0 : 1 }}
        />
        <g
          className="gauge-needle"
          style={{
            transform: `rotate(${fraction * SWEEP}deg)`,
            transformOrigin: `${CX}px ${CY}px`,
            opacity: value === null ? 0 : 1,
          }}
        >
          <line
            x1={CX}
            y1={CY}
            x2={tip.x}
            y2={tip.y}
            stroke="var(--needle)"
            strokeWidth="4"
            strokeLinecap="round"
          />
          <circle cx={CX} cy={CY} r={GAUGE.hubRadius} fill="var(--needle)" />
        </g>
        <text
          className="gauge-value"
          x={CX}
          y={GAUGE.valueBaseline}
          textAnchor="middle"
          fontSize={text.length > 4 ? 40 : 48}
        >
          {text}
        </text>
        <text className="gauge-unit" x={CX} y={GAUGE.unitBaseline} textAnchor="middle">
          tok/s
        </text>
        <text className="gauge-scale" x={start.x} y={end.y + 18} textAnchor="middle">
          0
        </text>
        <text className="gauge-scale" x={end.x} y={end.y + 18} textAnchor="middle">
          {max}
        </text>
      </svg>
      {caption && <figcaption>{caption}</figcaption>}
    </figure>
  );
}
