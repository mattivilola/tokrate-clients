import { invoke, isTauri } from "@tauri-apps/api/core";
import {
  DAY,
  cohort,
  label,
  client,
  clientLabel,
  measurementLabel,
  communityId,
  metricDefinition,
  alertsForCohorts,
  select,
  summarize,
  period,
  change,
  signal,
  buckets,
  type Metric,
  type Stats,
} from "./metrics";
import "./style.css";
import { AsyncGate } from "./async-gate";
interface Settings {
  sharing: boolean;
  monitoring: boolean;
  showSpeed: boolean;
  selection: string;
  days: number;
  root: string;
  claudeRoot: string;
  grokRoot: string;
}
interface Snapshot {
  settings: Settings;
  records: Metric[];
  status: string;
  monitorStatus: string;
  pending: number;
  board: any | null;
  revision: number;
  recordsChanged: boolean;
  smoke?: boolean;
}
const app = document.querySelector<HTMLDivElement>("#app")!;
const native = isTauri();
let state: Snapshot = {
  settings: {
    sharing: false,
    monitoring: true,
    showSpeed: true,
    selection: "latest",
    days: 1,
    root: "",
    claudeRoot: "",
    grokRoot: "",
  },
  records: [],
  status: "Loading local settings…",
  monitorStatus: "Starting monitoring…",
  pending: 0,
  board: null,
  revision: -1,
  recordsChanged: true,
};
let chartMetric: "throughput" | "ttft" = "throughput",
  error = "",
  busy = false,
  settingsOpen = false,
  historyOpen = false,
  sort = "recent";
const filters = { client: "all", provider: "all" };
const gate = new AsyncGate();
const e = (v: unknown) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const n = (v: number | null | undefined, d = 1) =>
  typeof v === "number" && Number.isFinite(v) ? v.toFixed(d) : "—";
const time = (v: string) =>
  Number.isFinite(Date.parse(v)) ? new Date(v).toLocaleString() : "Unavailable";
function gauge(value: number | null) {
  const max = Math.max(100, Math.ceil((value ?? 0) / 50) * 50),
    angle = ((-210 + Math.min(1, (value ?? 0) / max) * 240) * Math.PI) / 180;
  const x = 150 + 101 * Math.cos(angle),
    y = 143 + 101 * Math.sin(angle);
  return `<figure class="gauge"><svg viewBox="0 0 300 278" role="img" aria-label="Latest completed-turn throughput ${e(n(value))} tokens per whole-turn second"><circle cx="150" cy="143" r="129" fill="#f5fafb"/>${Array.from(
    { length: 25 },
    (_, i) => {
      const a = ((-210 + i * 10) * Math.PI) / 180,
        r = i % 5 === 0 ? 105 : 112;
      return `<line x1="${150 + r * Math.cos(a)}" y1="${143 + r * Math.sin(a)}" x2="${150 + 119 * Math.cos(a)}" y2="${143 + 119 * Math.sin(a)}" stroke="#60818d" stroke-width="${i % 5 === 0 ? 2 : 1}"/>`;
    },
  ).join(
    "",
  )}<text x="150" y="72" text-anchor="middle" fill="#60818d" font-size="12">${max / 2}</text>${value !== null ? `<line x1="150" y1="143" x2="${x}" y2="${y}" stroke="#d95143" stroke-width="4" stroke-linecap="round"/><circle cx="150" cy="143" r="6" fill="#d95143"/>` : ""}<text x="150" y="207" text-anchor="middle" fill="#173440" font-size="43" font-weight="700">${n(value)}</text><text x="150" y="228" text-anchor="middle" fill="#536e79" font-size="11">tokens / whole-turn second</text><text x="56" y="208" fill="#60818d" font-size="11">0</text><text x="232" y="208" fill="#60818d" font-size="11">${max}</text></svg><figcaption>Latest eligible completed turn</figcaption></figure>`;
}
function chart(rows: Metric[], now: number) {
  const b = buckets(rows, now, state.settings.days, chartMetric),
    valid = b.flatMap((p) => (p.value === null ? [] : [p.value]));
  const top = Math.max(1, ...valid) * 1.1;
  let path = "",
    connected = false;
  const dots = b
    .map((p, i) => {
      if (p.value === null) {
        connected = false;
        return "";
      }
      const x = 30 + (i * 500) / (b.length - 1),
        y = 133 - (p.value / top) * 112;
      path += `${connected ? "L" : "M"}${x},${y} `;
      connected = true;
      return `<circle cx="${x}" cy="${y}" r="3" fill="#0b97b4"><title>${e(time(new Date(p.at).toISOString()))}: ${n(p.value)}</title></circle>`;
    })
    .join("");
  return `<svg class="chart" viewBox="0 0 560 166" role="img" aria-label="${chartMetric === "throughput" ? "Whole-turn throughput" : "Reported TTFT"} history. Missing observations are gaps."><line x1="30" y1="133" x2="530" y2="133" stroke="#b8cbd1"/><text x="8" y="24">${n(top, 0)}</text><text x="16" y="137">0</text><path d="${path}" fill="none" stroke="#0b97b4" stroke-width="3"/>${dots}<text x="30" y="159">${state.settings.days === 1 ? "24 hours ago" : "7 days ago"}</text><text x="530" y="159" text-anchor="end">Now</text></svg>`;
}
function stat(s: Stats, title: string, unit: string) {
  return `<div class="stat"><small>${title}</small><span class="number">${n(s.median)} <small style="display:inline;font-size:14px">${unit}</small></span><small>Min ${n(s.min)} · Max ${n(s.max)}</small><small>${s.count} eligible measurements</small></div>`;
}
function comparisons(rows: Metric[]) {
  const groups = [...new Set(rows.map(cohort))].map((key) => {
    const r = rows.filter((m) => cohort(m) === key);
    return { key, rows: r, s: summarize(r) };
  });
  if (sort !== "recent")
    groups.sort((a, b) => {
      const definition = metricDefinition(a.rows[0]).localeCompare(
        metricDefinition(b.rows[0]),
      );
      if (definition) return definition;
      return sort === "throughput"
        ? (b.s.throughput.median ?? -1) - (a.s.throughput.median ?? -1)
        : (a.s.ttft.median ?? Infinity) - (b.s.ttft.median ?? Infinity);
    });
  return `<div class="panel"><div class="panel-head"><h2>Compare exact measurement cohorts</h2><select id="sort" aria-label="Comparison order"><option value="recent" ${sort === "recent" ? "selected" : ""}>Most recent</option><option value="throughput" ${sort === "throughput" ? "selected" : ""}>Higher throughput</option><option value="ttft" ${sort === "ttft" ? "selected" : ""}>Lower first-token wait</option></select></div>${groups.map((g) => `<div class="model-row"><div><strong>${e(g.rows[0].model ?? "Unknown model")}</strong><p class="muted">${e(clientLabel(g.rows[0]))} · ${e(g.rows[0].reasoningEffort ?? "unknown")} effort · ${e(g.rows[0].provider ?? "unknown")} provider</p><small>${e(measurementLabel(g.rows[0]))} · ${e(g.rows[0].clientVersion ?? "version unknown")} · ${e(g.rows[0].parserVersion ?? "codex-rollout-v1")} / ${e(g.rows[0].metricVersion ?? "turn-v1")}</small><br><small>${g.s.throughput.count} throughput / ${g.s.ttft.count} Codex TTFT samples</small></div><button data-cohort="${e(g.key)}">${n(g.s.throughput.median)} t/s<br><small>${n(g.s.ttft.median)} s Codex TTFT</small></button></div>`).join("") || '<p class="empty">Complete a supported coding-tool turn to compare exact cohorts.</p>'}<p class="notice">Different workloads and metric definitions affect these observations. This is not an answer-quality ranking.</p></div>`;
}
function community(selected: Metric[]) {
  if (!state.settings.sharing)
    return `<section class="panel"><h2>Community</h2><p class="empty">Sharing is off. Your local dashboard keeps working. Enable sharing to see community observations here.</p></section>`;
  const b = state.board;
  if (!b)
    return `<section class="panel"><h2>Community</h2><p class="empty">${e(state.status)}</p></section>`;
  const wanted = selected[0] && communityId(selected[0]);
  const rows = (Array.isArray(b.cohorts) ? b.cohorts : []).filter(
    (c: any) =>
      (state.settings.selection === "all" || c.id === wanted) &&
      (filters.client === "all" || c.client === filters.client) &&
      (filters.provider === "all" || c.provider === filters.provider),
  );
  const alerts = alertsForCohorts(
    Array.isArray(b.alerts) ? b.alerts : [],
    new Set(rows.map((c: any) => c.id)),
  );
  return `<section class="panel"><div class="panel-head"><h2>Community observations</h2><small>${e(b.window ?? "24h")}</small></div>${b.methodology?.publicationMode === "early_data" ? '<span class="badge">Early data · small sample</span>' : ""}<p class="muted">Processing: ${e(b.state ?? "unknown")} · Observations through ${e(time(b.dataAsOf ?? ""))}</p>${rows.map((c: any) => `<div class="model-row"><div><strong>${e(c.model)}</strong><p class="muted">${e(c.reasoningEffort ?? "unknown")} effort · ${e(c.contributors)} reporting installs</p><small>${e(c.throughputTurns ?? c.turns)} throughput / ${e(c.ttftTurns ?? 0)} TTFT turns</small></div><div><strong>${n(c.medianThroughput)} t/s</strong><p>${n(typeof c.medianTtftMs === "number" ? c.medianTtftMs / 1000 : null)} s TTFT</p></div></div><p class="notice">Throughput: ${e(c.signals?.throughput?.state ?? "insufficient evidence")}<br>First token: ${e(c.signals?.ttft?.state ?? "insufficient evidence")}</p>`).join("") || '<p class="empty">No published observations for this exact model and reasoning setting.</p>'}${alerts
    .map(
      (a: any) =>
        `<p class="notice">${e(a.message ?? `${a.metric ?? "Performance"}: ${a.state ?? "change observed"}`)}</p>`,
    )
    .join(
      "",
    )}<p class="muted" style="margin-top:14px">Missing alerts do not establish provider health. Geography, Fast mode and answer quality are not measured.</p></section>`;
}
function render() {
  const now = Date.now();
  const all = state.records.filter(
    (m) =>
      Date.parse(m.completedAt) >= now - 7 * DAY &&
      Date.parse(m.completedAt) <= now,
  );
  const filtered = all.filter(
    (m) =>
      (filters.client === "all" || client(m) === filters.client) &&
      (filters.provider === "all" || (m.provider ?? "unknown") === filters.provider),
  );
  const selected = select(filtered, state.settings.selection);
  const rows = period(selected, now - state.settings.days * DAY, now + 1);
  const summary = summarize(rows);
  const latest = rows.find((m) => m.outputTokens >= 20);
  const current = summarize(period(selected, now - DAY, now + 1));
  const previous = summarize(period(selected, now - 2 * DAY, now - DAY));
  const recent = summarize(period(selected, now - 900000, now + 1));
  const historyRows = period(
    state.settings.selection === "all" ? filtered : selected,
    now - state.settings.days * DAY,
    now + 1,
  );
  const keys = [...new Map(filtered.map((m) => [cohort(m), m])).entries()];
  const selectionSource = selected[0];
  const ttftTitle = selectionSource && client(selectionSource) !== "codex"
    ? "First-token latency is not captured for this source"
    : "Median Codex-reported TTFT";
  const ttftSignal = selectionSource && client(selectionSource) !== "codex"
    ? "First-token latency is not captured for this source"
    : signal(selected, now, "ttft");
  app.innerHTML = `<main>
    <header><div class="brand"><svg viewBox="0 0 32 32" aria-hidden="true"><circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" stroke-width="2.5"/><path d="M8 22a10 10 0 1 1 16 0M16 17l6-7" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="16" cy="17" r="2" fill="currentColor"/></svg>Tokrate</div><nav><button id="website" title="Open tokrate.dev in your browser">Global stats ↗</button><button id="settings-button" aria-label="Open settings">⚙</button></nav></header>
    ${!native ? '<p class="notice">Development preview · synthetic local data · no network sharing</p>' : ""}${error ? `<p role="alert" class="error">${e(error)}</p>` : ""}
    <div class="toolbar">
      <label><span>Coding tool</span><select id="client-filter"><option value="all" ${filters.client === "all" ? "selected" : ""}>All tools</option><option value="codex" ${filters.client === "codex" ? "selected" : ""}>Codex</option><option value="claude-code" ${filters.client === "claude-code" ? "selected" : ""}>Claude Code</option><option value="grok-build" ${filters.client === "grok-build" ? "selected" : ""}>Grok Build</option></select></label>
      <label><span>Provider route</span><select id="provider-filter"><option value="all" ${filters.provider === "all" ? "selected" : ""}>All routes</option><option value="openai" ${filters.provider === "openai" ? "selected" : ""}>OpenAI</option><option value="anthropic" ${filters.provider === "anthropic" ? "selected" : ""}>Anthropic</option><option value="xai" ${filters.provider === "xai" ? "selected" : ""}>xAI</option><option value="unknown" ${filters.provider === "unknown" ? "selected" : ""}>Unknown</option></select></label>
      <label><span>Model and reasoning cohort</span><select id="cohort"><option value="latest">Latest exact cohort</option><option value="all" ${state.settings.selection === "all" ? "selected" : ""}>Compare all exact cohorts</option>${keys.map(([key, m]) => `<option value="${e(key)}" ${state.settings.selection === key ? "selected" : ""}>${e(label(m))}</option>`).join("")}</select></label>
      <div class="segments" aria-label="History range"><button data-days="1" aria-pressed="${state.settings.days === 1}">24 hours</button><button data-days="7" aria-pressed="${state.settings.days === 7}">7 days</button></div>
    </div>
    ${state.settings.selection === "all" ? comparisons(period(filtered, now - state.settings.days * DAY, now + 1)) : `<section class="instrument">${gauge(latest?.turnThroughputTPS ?? null)}<div><h1>${e(selected[0]?.model ?? "Waiting for a completed turn")}</h1><small>${e(selected[0] ? clientLabel(selected[0]) : "All coding tools")} · ${e(selected[0]?.reasoningEffort ?? "unknown")} reasoning effort</small><p>${e(selected[0] ? measurementLabel(selected[0]) : "Measurements remain separated by coding tool, source, model and version.")}. Streaming speed is not inferred.</p><span class="timestamp">${latest ? "Completed " + e(time(latest.completedAt)) : "Complete a turn with at least 20 output tokens."}</span></div></section>
      <section class="panel"><div class="panel-head"><h2>Your pace</h2><div class="segments"><button data-metric="throughput" aria-pressed="${chartMetric === "throughput"}">Throughput</button><button data-metric="ttft" aria-pressed="${chartMetric === "ttft"}">First token · Codex</button></div></div>${chart(rows, now)}<small>Bucket medians · gaps mean no observations</small><div class="stats">${stat(summary.throughput, `Median ${selectionSource ? measurementLabel(selectionSource).toLowerCase() : "turn throughput"}`, "t/s")}${stat(summary.ttft, ttftTitle, "seconds")}</div></section>
      <section class="panel"><h2>Now and previously</h2><div class="decision"><div><p class="muted">Last 15 minutes</p><p><strong>${n(recent.throughput.median)} t/s</strong> · ${n(recent.ttft.median)} s TTFT</p><small>${recent.throughput.count} / ${recent.ttft.count} measurements</small></div><div><p class="muted">24 hours vs previous 24 hours</p><p>Throughput ${n(change(current.throughput, previous.throughput))}%</p><p>First-token wait ${n(change(current.ttft, previous.ttft))}%</p><small>Needs 5 samples in each period.</small></div></div><p class="notice">${e(signal(selected, now, "throughput"))}<br>${e(ttftSignal)}<br><small>Your workload may have changed.</small></p></section>`}
    <section class="panel"><div class="share-row"><div><h2>Share with community</h2><p class="muted">${e(state.status)}${state.pending ? ` · ${state.pending} queued` : ""}</p></div><label class="switch"><input id="sharing" type="checkbox" ${state.settings.sharing ? "checked" : ""} aria-label="Share with community"></label></div><p style="margin-top:12px" class="muted">No prompts, responses or code in uploads. Performance reports use a persistent random signing identity. Sharing is on by default and can be switched off here.</p><button id="retry" style="margin-top:12px" ${!state.settings.sharing ? "disabled" : ""}>Retry sharing</button></section>
    ${community(selected)}
    <details class="panel settings" ${settingsOpen ? "open" : ""}><summary>Settings & monitoring</summary><div class="settings-content"><p>${e(state.monitorStatus)}</p><label class="switch"><input id="monitoring" type="checkbox" ${state.settings.monitoring ? "checked" : ""}>Monitor local coding-tool sessions</label><label class="switch"><input id="showSpeed" type="checkbox" ${state.settings.showSpeed ? "checked" : ""}>Show speed in tray tooltip/menu</label><small>Adjacent tray text is only available on supported desktops. Values update after completed turns.</small>
      <div><p class="path"><strong>Codex sessions:</strong> ${e(state.settings.root || "Default Codex sessions folder")}</p><button data-folder="codex">Choose folder…</button></div>
      <div><p class="path"><strong>Claude Code projects:</strong> ${e(state.settings.claudeRoot || "Default Claude Code projects folder")}</p><button data-folder="claude-code">Choose folder…</button></div>
      <div><p class="path"><strong>Grok Build sessions:</strong> ${e(state.settings.grokRoot || "Default Grok Build sessions folder")}</p><button data-folder="grok-build">Choose folder…</button></div>
      <p class="muted">Pausing monitoring does not stop queued uploads. Turn sharing off to stop all community requests. Previously received reports cannot be recalled by the switch.</p><button id="quit">Quit Tokrate</button></div></details>
    <details class="panel history" ${historyOpen ? "open" : ""}><summary>Turn history (${Math.min(500, historyRows.length)} shown)</summary><div class="table-scroll"><table><thead><tr><th>Completed</th><th>Coding tool / model</th><th>Tokens</th><th>Throughput</th><th>Codex TTFT</th></tr></thead><tbody>${historyRows.slice(0, 500).map((m) => `<tr><td>${e(time(m.completedAt))}</td><td>${e(clientLabel(m))} · ${e(m.model ?? "Unknown")}<br>${e(m.reasoningEffort ?? "unknown")} effort · ${e(m.provider ?? "unknown")} provider</td><td>${m.outputTokens}</td><td>${n(m.turnThroughputTPS)} t/s<br><small>${e(measurementLabel(m))}</small></td><td>${n(m.codexTTFTSeconds)}</td></tr>`).join("")}</tbody></table></div></details>
    <footer>Local history: 7 days. Community data refreshes at most every 30 seconds while sharing is on. Measurements use source-specific definitions and do not rate answer quality or verify provider outages. <button id="privacy">Privacy & methodology</button></footer>
  </main>`;
  bind();
}
async function action(fn: () => Promise<Snapshot | void>) {
  const epoch = gate.beginMutation();
  busy = true;
  try {
    const next = await fn();
    if (gate.isLatest(epoch)) {
      if (next) state = next;
      error = "";
    }
  } catch {
    if (gate.isLatest(epoch))
      error =
        "The change could not be saved. Review your settings and try again.";
  } finally {
    gate.finishMutation();
    busy = gate.pending > 0;
    render();
    if (!busy) void refresh();
  }
}
async function patch(p: Partial<Settings>) {
  await action(async () => {
    if (native) return invoke<Snapshot>("update_settings", { patch: p });
    state.settings = { ...state.settings, ...p };
  });
}
function bind() {
  const on = (id: string, fn: () => void) =>
    document.getElementById(id)?.addEventListener("click", fn);
  document
    .getElementById("client-filter")
    ?.addEventListener("change", (ev) => {
      filters.client = (ev.target as HTMLSelectElement).value;
      void patch({ selection: "latest" });
    });
  document
    .getElementById("provider-filter")
    ?.addEventListener("change", (ev) => {
      filters.provider = (ev.target as HTMLSelectElement).value;
      void patch({ selection: "latest" });
    });
  document
    .getElementById("cohort")
    ?.addEventListener(
      "change",
      (ev) => void patch({ selection: (ev.target as HTMLSelectElement).value }),
    );
  document.getElementById("sort")?.addEventListener("change", (ev) => {
    sort = (ev.target as HTMLSelectElement).value;
    render();
  });
  for (const key of ["sharing", "monitoring", "showSpeed"] as const)
    document
      .getElementById(key)
      ?.addEventListener(
        "change",
        (ev) => void patch({ [key]: (ev.target as HTMLInputElement).checked }),
      );
  document
    .querySelectorAll<HTMLButtonElement>("[data-days]")
    .forEach(
      (b) => (b.onclick = () => void patch({ days: Number(b.dataset.days) })),
    );
  document
    .querySelectorAll<HTMLButtonElement>("[data-cohort]")
    .forEach(
      (b) => (b.onclick = () => void patch({ selection: b.dataset.cohort! })),
    );
  document.querySelectorAll<HTMLButtonElement>("[data-metric]").forEach(
    (b) =>
      (b.onclick = () => {
        chartMetric = b.dataset.metric as typeof chartMetric;
        render();
      }),
  );
  document.querySelector(".settings")?.addEventListener("toggle", (ev) => {
    settingsOpen = (ev.target as HTMLDetailsElement).open;
  });
  document.querySelector(".history")?.addEventListener("toggle", (ev) => {
    historyOpen = (ev.target as HTMLDetailsElement).open;
  });
  on("settings-button", () => {
    settingsOpen = true;
    render();
    document
      .querySelector(".settings")
      ?.scrollIntoView({ behavior: "instant" });
  });
  on("website", () => {
    if (native) void invoke("open_website", { page: "home" });
    else window.open("https://tokrate.dev", "_blank", "noopener,noreferrer");
  });
  on("privacy", () => {
    if (native) void invoke("open_website", { page: "privacy" });
    else
      window.open(
        "https://tokrate.dev/privacy",
        "_blank",
        "noopener,noreferrer",
      );
  });
  on(
    "retry",
    () =>
      void action(async () => {
        if (native) return invoke<Snapshot>("retry_sharing");
      }),
  );
  document.querySelectorAll<HTMLButtonElement>("[data-folder]").forEach((button) => {
    button.onclick = () =>
      void action(async () => {
        if (native)
          return invoke<Snapshot>("choose_folder", {
            source: button.dataset.folder,
          });
      });
  });
  on("quit", () => {
    if (native) void invoke("quit");
  });
}
async function refresh() {
  if (busy || document.hidden || document.activeElement?.tagName === "SELECT")
    return;
  const epoch = gate.epoch;
  try {
    if (native) {
      const next = await invoke<Snapshot>("snapshot", {
        sinceRevision: state.revision < 0 ? null : state.revision,
      });
      if (!gate.accepts(epoch)) return;
      const changed =
        next.recordsChanged ||
        JSON.stringify({ ...next, records: [] }) !==
          JSON.stringify({ ...state, records: [], recordsChanged: false });
      if (!changed) return;
      state = {
        ...next,
        records: next.recordsChanged ? next.records : state.records,
      };
      render();
      if (state.smoke) {
        const codex = state.records.find(
          (m) => client(m) === "codex" && m.model === "fixture-model",
        );
        const claude = state.records.find(
          (m) => client(m) === "claude-code" && m.model === "claude-fixture-model",
        );
        const grok = state.records.find(
          (m) => client(m) === "grok-build" && m.model === "grok-fixture-model",
        );
        const approximately = (actual: number, expected: number) =>
          Math.abs(actual - expected) < 0.000001;
        if (codex && claude && grok) {
          if (
            !approximately(codex.turnThroughputTPS, 20) ||
            !approximately(claude.turnThroughputTPS, 30) ||
            !approximately(grok.turnThroughputTPS, 24) ||
            claude.codexTTFTSeconds !== null ||
            grok.codexTTFTSeconds !== null ||
            !document.querySelector(".gauge") ||
            state.settings.sharing
          )
            throw new Error("Smoke source metrics assertion");
          await invoke("smoke_complete");
        }
      }
    }
  } catch {
    error = "Cannot reach the local monitor. Restart Tokrate to reconnect.";
    render();
  }
}
if (!native) {
  const now = Date.now();
  state.status = "Preview: local only";
  state.monitorStatus = "Preview: monitoring simulated";
  state.records = Array.from({ length: 72 }, (_, i) => ({
    id: `demo-${i}`,
    completedAt: new Date(now - i * 1800000).toISOString(),
    model: i % 3 ? "Example model A" : "Example model B",
    provider: "openai",
    client: "codex",
    parserVersion: "codex-rollout-v1",
    metricVersion: "turn-v1",
    sourceKind: "primary",
    clientVersion: "example",
    reasoningEffort: i % 3 ? "high" : "medium",
    outputTokens: 300,
    durationSeconds: 15,
    codexTTFTSeconds: 2 + (i % 5) / 2,
    turnThroughputTPS: 12 + (i % 9) * 2,
  }));
}
render();
void refresh();
setInterval(() => void refresh(), 5000);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) void refresh();
});
