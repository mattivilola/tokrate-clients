# Tokrate design language

One visual language for the Mac menu-bar app, the Windows/Linux tray app and tokrate.dev (public board and admin). Every surface answers one question first — *how fast is my coding model right now, and which one is fastest?* — and keeps the precise definitions one click away.

## Principles

1. **Answer first.** The first thing on every surface is a number with a model name. Filters, definitions and coverage come after.
2. **Honest, not noisy.** Caveats are never deleted; they move into a single info affordance (ⓘ popover, `.help` tooltip or the methodology page). Each number keeps a short inline qualifier ("whole turn · incl. tools"). Never present whole-turn throughput as streaming speed.
3. **Hide what is empty.** A module with no evidence collapses to one status line ("Collecting baseline · day 1 of 3") instead of showing several "Unavailable" panels.
4. **Calm instrument.** Static by default. One short eased transition when a value changes (respect reduced motion). No continuous animation, no ticking clocks.
5. **Same words everywhere.** Use the vocabulary table below in UI copy on all surfaces.

## Brand

- **Mark:** an ink rounded tile with a 240° cyan→teal arc and a red-orange needle (`tokrate-mark.svg`). It replaces the former blue pulse tile and the generic speedometer symbol. The Mac menu-bar item uses a monochrome template version of the same arc + needle.
- **Wordmark:** "Tokrate", semibold, tight tracking (-0.02em). No descriptor line in compact headers.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48"><defs><linearGradient id="a" x1="0" x2="1"><stop offset="0" stop-color="#1E9BB5"/><stop offset="1" stop-color="#3CCFB4"/></linearGradient></defs><rect width="48" height="48" rx="12" fill="#0B2530"/><path d="M11.9 33A14 14 0 1 1 36.1 33" fill="none" stroke="url(#a)" stroke-width="4" stroke-linecap="round"/><path d="M24 26 31.1 18.9" stroke="#FF6B4A" stroke-width="3.5" stroke-linecap="round"/><circle cx="24" cy="26" r="2.8" fill="#FF6B4A"/></svg>
```

## Color tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg` | `#F4F7F8` | `#0A1A20` | Page / window background (cool grey, never cream) |
| `surface` | `#FFFFFF` | `#10252D` | Cards, popovers |
| `surface-2` | `#EEF3F5` | `#16303A` | Insets, segmented-control track, table header |
| `line` | `#DCE5E9` | `#23414C` | Hairlines, card borders |
| `ink` | `#0B2530` | `#E8F1F3` | Primary text, brand tile |
| `muted` | `#5B6F78` | `#9DB3BB` | Secondary text (meets AA on bg and surface) |
| `accent` | `#0F7C86` | `#4FD1C5` | Links, selected state, primary button background (light) |
| `accent-strong` | `#0A5F68` | `#7FE3D8` | Hover/pressed accent |
| `arc-start` → `arc-end` | `#1E9BB5` → `#3CCFB4` | same | Gauge arc, sparkline stroke, chart line |
| `needle` | `#E4572E` | `#FF7A55` | Gauge needle and hub only (never for errors) |
| `warn` | `#B7791F` | `#F2B24C` | Slower-than-usual, early-data, alpha labels |
| `good` | `#2E8F62` | `#5BC98F` | Recovery observed, sharing on |
| `danger` | `#C8423B` | `#F07A72` | Errors only |

Primary buttons: `accent` background with white text in light mode; `accent` background with `ink`-dark text (`#062026`) in dark mode. Radius 10px — never pill-shaped.

## Typography

- **Web:** Geist (variable, self-hosted via `@fontsource-variable/geist`), fallback `system-ui`. Numbers always `font-variant-numeric: tabular-nums`.
- **Mac:** system SF Pro; large readouts use `.rounded` design. Minimum 11 pt for any text.
- **Windows/Linux:** `"Segoe UI Variable", "Segoe UI", Cantarell, Ubuntu, system-ui, sans-serif`. Minimum 12 px.
- Scale (web px): 12 caption · 14 body-small · 16 body · 20 title-3 · 28 title-2 · 44–56 display. Hero readout 56–72.
- No monospace labels, no italic accent words, no numbered "01/02" section labels.

## Spacing, shape, elevation

- 4 px grid. Card padding 20–24 (web), 14–16 (popovers).
- Radius: cards 16, controls 10, chips 8.
- Elevation: hairline border + very soft shadow (`0 1px 2px rgb(11 37 48 / .06), 0 8px 24px rgb(11 37 48 / .06)`); dark mode uses border only.
- Focus ring: 2 px `accent`, 2 px offset, on every interactive element.

## The gauge (all surfaces)

- 240° sweep starting at 150° (lower-left) to 30° (lower-right).
- Track: `line` color, round caps. Active arc: `arc-start → arc-end` gradient up to the value.
- Needle: `needle` color, round cap, hub dot in `needle`; drawn only when a value exists.
- Readout sits in the open lower segment of the arc, fully below the hub: large tabular number + unit `tok/s` on the next line in `muted`. The needle (length ≈ radius − 14) and hub never overlap the readout.
- Scale: the "nice" ceiling of 1.25 × the largest median within the selected value's measurement group (same coding tool, metric version and source kind), using steps 20, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000; minimum 20. Label only 0 and max. Values from other measurement definitions never stretch the scale. Response speed is a single definition across coding tools, so its scale uses the 24 h medians of every model's per-turn response speed. The tokrate.dev Turn speed list ranks all coding tools together, so its rows and detail gauge share one scale over the visible list.
- Empty state: track only, readout "—", caption "Waiting for a completed turn".
- One eased transition (≈400 ms) when the value changes; none under `prefers-reduced-motion`.

## Charts

- Line in arc gradient (or `arc-end` solid), optional min–max band at 12% opacity, gaps for missing buckets, single bucket = dot.
- 3 horizontal gridlines in `line`; axis labels 12 px `muted`.
- Hover/focus crosshair with a tooltip: time · value · turns. Keyboard reachable on web.
- One shared implementation per platform (web: one React component used by public board and admin).

## Vocabulary

| Use | Instead of |
|---|---|
| **Response speed** · `tok/s` (primary metric) | streaming speed, generation speed, live decode rate |
| **Turn speed** · `tok/s` (secondary) | whole-turn throughput, t/s, tokens / whole-turn second |
| Measurement group names: **Codex · Turn speed**, **Claude Code · Turn speed**, **Claude Code · Subagent turn speed**, **Grok Build · Work-turn speed** (on the web board a row shows them as a tool chip plus a Subagent or Work turn chip) | "Whole-turn throughput", "Transcript-observed turn throughput" (the precise definition lives in the ⓘ explanation) |
| **First token** · `s` | TTFT, reported first-token wait |
| **Turns** | eligible turns, samples |
| **Contributors** | reporting installations, reporting keys (public); admin may say "reporting installations" |
| **Subagent turn** | sidechain |
| **Coding tool** (Codex, Claude Code, Grok Build) | client, source |
| **Effort** (low/medium/high/xhigh/unknown) | reasoning effort setting |
| **Collecting data** | insufficient data, building evidence |
| Relative times ("5 min ago") with exact time in tooltip | locale timestamps inline |

The one-line definition shown next to a response-speed readout: "Output tokens per second while the model is responding — tools and your time excluded." The one next to a turn-speed readout: "Whole turn, including tools and waiting." The info affordance links to the full methodology.

## Information architecture

### tokrate.dev public board
1. Compact header: mark + wordmark, nav (Board, Download, Methodology), theme toggle.
2. Hero line + **leaderboard**: one ranked list per view; a row is one model (grouped across effort) with its maker badge, neutral coding-tool chip(s), median, sparkline, coverage, live dot. Turn speed keeps one row per model and coding tool and never pools tools. Coding-tool segmented control + window segmented control + "Filters" popover (provider, effort, tool version).
3. Selecting a row opens the **model detail**: gauge, first token, range, history chart with hover, period change; effort chips switch the exact cohort.
4. Status strip (one line): early data, stale, alerts.
5. Usage breakdown and detailed table behind disclosures. Filter state lives in the URL.

### Mac popover / Windows-Linux tray flyout (same IA)
1. Header: mark, model picker (single control), gear menu.
2. Hero: live response speed (large; median of the last 5 responses in the last 10 minutes, caption "last 5 responses · 2 min ago"), provider badge + model + effort chip, change vs your 24 h response-speed median. The header picker offers Auto (most active), Auto within a coding tool, and pinned models.
3. Sparkline for the selected model (24 h / 7 d).
4. "Your models" list: model + provider badge, tool chips, response-speed median, mini bar, turn speed as secondary text; click selects.
5. Community line (when sharing): community median and your relative position.
6. Footer: monitoring + sharing status dot, "Open tokrate.dev".
Settings live in a proper Settings window (General, Sharing, Sources, Updates). Full history stays available from the gear menu.

### First launch (desktop clients)
Three steps: Welcome with detected sources (Codex / Claude Code / Grok Build found or not) → Sharing choice with two equal-weight buttons and "See exactly what is sent" (sample payload) → "Find Tokrate in your menu bar / tray". The affirmative-consent rules in `metrics-contract.md` are unchanged.

### Admin telemetry
KPI strip (contributors 24 h / 30 d / ever, retained reports vs capacity, snapshot health per window, latest sample age) → tabs: Overview, Cohorts, Data quality, Rules. Early data is a real switch with confirmation.
