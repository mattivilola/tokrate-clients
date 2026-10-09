import { ArrowDown, ArrowUp } from "lucide-react";
import { GROK_RESPONSE_EXPLANATION, GROK_RESPONSE_NOTE, isGrokBuild, toolLabel } from "../metrics";
import type { Dashboard } from "../model/dashboard";
import { effortChip, exactTime, num, signedPercent } from "../model/format";
import { Gauge } from "./Gauge";
import { Chip, InfoDisclosure, ProviderBadge } from "./primitives";

/** Vocabulary definition shown next to the response-speed readout. */
export const RESPONSE_DEFINITION =
  "Output tokens per second while the model is responding — tools and your time excluded.";

/** "last 5 responses · 2 min ago" for the live value; the newest turn's own timing otherwise. */
export function heroCaption(dashboard: Dashboard): string {
  const { hero, heroRelative } = dashboard;
  if (hero.value === null) return "Waiting for a response";
  if (hero.source === "live")
    return `last ${hero.count} ${hero.count === 1 ? "response" : "responses"} · ${heroRelative}`;
  return `latest turn · ${heroRelative}`;
}

export function Hero({ dashboard }: { dashboard: Dashboard }) {
  const { hero, responseDelta, activeKey, sample, liveLatest, scopeTools, heroTurn } = dashboard;
  const grokHero = hero.source === "turn" && isGrokBuild(heroTurn);
  const rounded = responseDelta ? Math.round(responseDelta.percent) : 0;
  const caption = heroCaption(dashboard);
  const effort = sample ? effortChip(sample) : liveLatest?.reasoningEffort ? `${liveLatest.reasoningEffort} effort` : null;
  const label =
    hero.value === null
      ? "No response yet"
      : `Response speed ${num(hero.value)} tokens per second, ${caption}. ${RESPONSE_DEFINITION}${grokHero ? ` ${GROK_RESPONSE_NOTE}.` : ""}`;
  const completedAt =
    hero.at === null ? null : new Date(hero.at).toISOString();
  return (
    <section className="hero" aria-label="Response speed">
      <Gauge
        value={hero.value}
        max={dashboard.gaugeMax}
        label={label}
        caption={caption}
      />
      {activeKey && hero.value !== null ? (
        <div className="hero-meta">
          <h1 className="hero-model">
            <ProviderBadge model={activeKey.model} provider={activeKey.provider} size={22} />
            <span className="hero-model-name">{activeKey.model ?? "Unknown model"}</span>
            {effort && (
              <Chip tone={effort === "effort unknown" ? "neutral" : "accent"}>{effort}</Chip>
            )}
          </h1>
          <p className="hero-sub">
            <span>
              {(scopeTools.length
                ? scopeTools.map(toolLabel)
                : liveLatest
                  ? [toolLabel(liveLatest.client)]
                  : []
              ).join(" + ")}
            </span>
            {completedAt && (
              <>
                <span aria-hidden="true">·</span>
                <time dateTime={completedAt} title={`Updated ${exactTime(completedAt)}`}>
                  {dashboard.heroRelative}
                </time>
              </>
            )}
          </p>
          {responseDelta && (
            <p
              className={`delta ${rounded > 0 ? "delta-up" : rounded < 0 ? "delta-down" : ""}`}
              title={`Your 24 h response-speed median is ${num(responseDelta.median)} tok/s across ${responseDelta.turns} turns`}
            >
              {rounded > 0 && <ArrowUp size={16} aria-hidden="true" />}
              {rounded < 0 && <ArrowDown size={16} aria-hidden="true" />}
              <span>
                {rounded === 0
                  ? "On par with your 24 h median"
                  : `${signedPercent(responseDelta.percent)} vs your 24 h median`}
              </span>
            </p>
          )}
          <p className="definition">
            <span title={grokHero ? GROK_RESPONSE_EXPLANATION : undefined}>
              {RESPONSE_DEFINITION}
              {grokHero && ` ${GROK_RESPONSE_NOTE}.`}
            </span>
            <InfoDisclosure label="About response speed">
              <strong>Response speed</strong> · Each API response is timed from the request that
              triggered it (your prompt, a tool result or a notification) to the response&apos;s
              last output record. Only responses with at least 200 output tokens count, so tiny
              check-ins never move it. The large number is the median of your last 5 responses
              from the past 10 minutes, or the newest turn&apos;s own responses when none are
              live.
              {grokHero && (
                <>
                  <br />
                  {GROK_RESPONSE_EXPLANATION}
                </>
              )}
              <br />
              Turn speed — a whole turn including tools and waiting — stays available as the
              secondary measurement. Neither is streaming speed, and Tokrate never infers
              streaming speed.
            </InfoDisclosure>
          </p>
        </div>
      ) : (
        <div className="hero-meta">
          <p className="hero-empty">
            {dashboard.hasRecords
              ? "No response speed for this selection yet. Complete a response of at least 200 output tokens in Claude Code, Codex, Antigravity, OpenCode or Kimi Code."
              : "Complete a response of at least 200 output tokens in a supported coding tool."}
          </p>
        </div>
      )}
    </section>
  );
}
