import { ArrowDown, ArrowUp } from "lucide-react";
import {
  clientLabel,
  measurementChip,
  measurementDefinition,
  measurementExplanation,
  measurementLabel,
} from "../metrics";
import type { Dashboard } from "../model/dashboard";
import { effortChip, exactTime, modelName, num, signedPercent } from "../model/format";
import { Gauge } from "./Gauge";
import { Chip, InfoDisclosure } from "./primitives";

export function Hero({ dashboard }: { dashboard: Dashboard }) {
  const { latest, sample, delta } = dashboard;
  const value = latest?.turnThroughputTPS ?? null;
  const rounded = delta ? Math.round(delta.percent) : 0;
  const chip = latest ? measurementChip(latest) : null;
  const label =
    value === null
      ? "No completed turn yet"
      : `Latest turn speed ${num(value)} tokens per second, ${measurementDefinition(latest).toLowerCase()}`;
  return (
    <section className="hero" aria-label="Latest turn speed">
      <Gauge
        value={value}
        label={label}
        caption={value === null ? "Waiting for a completed turn" : undefined}
      />
      {latest && sample ? (
        <div className="hero-meta">
          <h1 className="hero-model">
            <span className="hero-model-name">{modelName(latest)}</span>
            <Chip tone={effortChip(latest) === "effort unknown" ? "neutral" : "accent"}>
              {effortChip(latest)}
            </Chip>
            {chip && <Chip title={measurementDefinition(latest)}>{chip}</Chip>}
          </h1>
          <p className="hero-sub">
            <span>{clientLabel(latest)}</span>
            <span aria-hidden="true">·</span>
            <time
              dateTime={latest.completedAt}
              title={`Completed ${exactTime(latest.completedAt)}`}
            >
              {dashboard.latestRelative}
            </time>
          </p>
          {delta && (
            <p
              className={`delta ${rounded > 0 ? "delta-up" : rounded < 0 ? "delta-down" : ""}`}
              title={`Your 24 h median is ${num(delta.median)} tok/s across ${delta.turns} turns`}
            >
              {rounded > 0 && <ArrowUp size={16} aria-hidden="true" />}
              {rounded < 0 && <ArrowDown size={16} aria-hidden="true" />}
              <span>
                {rounded === 0
                  ? "On par with your 24 h median"
                  : `${signedPercent(delta.percent)} vs your 24 h median`}
              </span>
            </p>
          )}
          <p className="definition">
            <span>{measurementDefinition(latest)}</span>
            <InfoDisclosure label="About turn speed">
              <strong>{measurementLabel(latest)}</strong>
              {measurementExplanation(latest) && ` · ${measurementExplanation(latest)}`}
              <br />
              Turn speed is completed output tokens divided by the whole turn,
              including tool time and waiting. It is not streaming speed, and
              Tokrate never infers streaming speed.
            </InfoDisclosure>
          </p>
        </div>
      ) : (
        <div className="hero-meta">
          <p className="hero-empty">
            {dashboard.hasRecords
              ? "No turn matches this filter yet."
              : "Complete a turn with at least 20 output tokens in a supported coding tool."}
          </p>
        </div>
      )}
    </section>
  );
}
