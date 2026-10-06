import { useEffect, type ReactNode } from "react";
import { ArrowLeft, ArrowUpRight, Check, FolderOpen, Minus, RotateCcw } from "lucide-react";
import { client } from "../metrics";
import { folderName, SOURCE_TITLES } from "../model/format";
import {
  DELEGATED_NOTICE,
  PROMPT_CACHE_NOTICE,
  REGION_NOTICE,
  SURFACE_NOTICE,
  buildSentExample,
} from "./SharingChoice";
import { useStore } from "../store/store";
import type { SourceId, SourceStatus } from "../store/types";
import { Chip, Disclosure, StatusDot, Switch, useAppStore } from "./primitives";
import { UpdatesSection } from "./Updates";

function Section({
  id,
  title,
  children,
}: {
  id: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="card settings-section" id={id} aria-labelledby={`${id}-title`}>
      <h2 id={`${id}-title`}>{title}</h2>
      {children}
    </section>
  );
}

function SwitchRow({
  id,
  label,
  hint,
  checked,
  onChange,
  disabled,
}: {
  id: string;
  label: string;
  hint?: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <div className="switch-row">
      <div>
        <p className="switch-label" id={`${id}-label`}>
          {label}
        </p>
        {hint && (
          <p className="hint" id={`${id}-hint`}>
            {hint}
          </p>
        )}
      </div>
      <Switch
        checked={checked}
        onChange={onChange}
        label={label}
        describedBy={hint ? `${id}-hint` : undefined}
        disabled={disabled}
      />
    </div>
  );
}

function SourceRow({ source, turns }: { source: SourceStatus; turns: number }) {
  const store = useAppStore();
  const title = SOURCE_TITLES[source.id];
  return (
    <li className="source-row">
      <div className="source-main">
        <p className="source-name">
          <span>{title}</span>
          {source.found ? (
            <Chip tone="accent">
              <Check size={12} aria-hidden="true" /> Found
            </Chip>
          ) : (
            <Chip>
              <Minus size={12} aria-hidden="true" /> Not found
            </Chip>
          )}
        </p>
        <p className="hint" title={source.root}>
          {source.isDefault ? "Default folder" : "Custom folder"} ·{" "}
          {folderName(source.root)}
          {turns > 0 && ` · ${turns} ${turns === 1 ? "turn" : "turns"} in 7 d`}
        </p>
      </div>
      <div className="source-actions">
        <button
          type="button"
          className="btn btn-secondary btn-sm"
          aria-label={`Choose ${title} folder`}
          onClick={() => void store.chooseFolder(source.id)}
        >
          <FolderOpen size={16} aria-hidden="true" />
          Choose…
        </button>
        <button
          type="button"
          className="btn btn-secondary btn-sm"
          aria-label={`Reset ${title} folder to default`}
          disabled={source.isDefault}
          onClick={() => void store.resetFolder(source.id)}
        >
          <RotateCcw size={16} aria-hidden="true" />
          Reset to default
        </button>
      </div>
    </li>
  );
}

export function SettingsView() {
  const store = useAppStore();
  const snapshot = useStore(store, (s) => s.snapshot);
  const anchor = useStore(store, (s) => s.ui.settingsAnchor);
  const { settings } = snapshot;
  const sources = snapshot.sources ?? [];
  const turnsBy = (id: SourceId) =>
    snapshot.records.filter((m) => client(m) === id).length;

  useEffect(() => {
    if (!anchor) return;
    document.getElementById(anchor)?.scrollIntoView({ block: "start" });
    store.clearSettingsAnchor();
  }, [anchor, store]);

  return (
    <div className="settings-view">
      <header className="topbar topbar-settings">
        <button
          type="button"
          className="icon-button"
          aria-label="Back to dashboard"
          onClick={() => store.setView("home")}
        >
          <ArrowLeft size={20} aria-hidden="true" />
        </button>
        <h1>Settings</h1>
      </header>
      <div className="scroll">
        <Section id="settings-general" title="General">
          <SwitchRow
            id="show-speed"
            label="Show speed in tray"
            hint="The response speed of the model you are using, as in the dashboard: the median of its last 5 responses from the past 10 minutes while responses finish, otherwise the response speed of its latest turn. Shown in the tray tooltip and menu; adjacent tray text only on supported desktops. It shows — when nothing has been measured yet or monitoring is paused."
            checked={settings.showSpeed}
            onChange={(showSpeed) => void store.patch({ showSpeed })}
          />
          <SwitchRow
            id="show-provider-badge"
            label="Show provider badge"
            hint="A filled circle with the provider's letter (A Anthropic, O OpenAI, X xAI, G Google) next to the model: in the tray icon where the desktop allows icon updates, and in this window."
            checked={settings.showProviderBadge}
            onChange={(showProviderBadge) => void store.patch({ showProviderBadge })}
          />
          <SwitchRow
            id="show-tool-chip"
            label="Show coding tool chip"
            hint="Two letters for the coding tool (CX Codex, CC Claude Code, GB Grok Build, AG Antigravity, OC OpenCode) before the speed in the tray text, where the desktop shows adjacent text. The tray tooltip always names the tool."
            checked={settings.showToolChip}
            onChange={(showToolChip) => void store.patch({ showToolChip })}
          />
          <SwitchRow
            id="monitoring"
            label="Monitor coding-tool sessions"
            hint={snapshot.monitorStatus}
            checked={settings.monitoring}
            onChange={(monitoring) => void store.patch({ monitoring })}
          />
          <p className="fine">
            Pausing monitoring does not stop queued uploads. Turn sharing off to stop all
            community requests.
          </p>
        </Section>

        <Section id="settings-sharing" title="Sharing">
          <SwitchRow
            id="sharing"
            label="Share with community"
            hint={
              settings.sharing
                ? "On. New turn measurements, with their response timing, are shared."
                : "Off. Your dashboard keeps working locally."
            }
            checked={settings.sharing}
            onChange={(enabled) => {
              if (enabled) store.setConsentSheet(true);
              else void store.disableSharing();
            }}
          />
          <p className="status-line" role="status">
            <StatusDot tone={settings.sharing ? "good" : "muted"} />
            <span>
              {snapshot.status}
              {snapshot.pending ? ` · ${snapshot.pending} queued` : ""}
            </span>
          </p>
          <div className="row-actions">
            <button
              type="button"
              className="btn btn-secondary btn-sm"
              disabled={!settings.sharing}
              onClick={() => void store.retrySharing()}
            >
              Retry sharing
            </button>
          </div>
          <p className="fine">
            Contribution is off until you choose. No prompts, responses, code or local file
            paths are uploaded. {REGION_NOTICE} {DELEGATED_NOTICE} {SURFACE_NOTICE} {PROMPT_CACHE_NOTICE} You can withdraw at any time: turning sharing off stops future
            community requests and clears queued reports. Reports already received cannot be
            recalled by the switch.
          </p>
          <Disclosure label="See exactly what is sent">
            <pre className="payload" tabIndex={0} aria-label="Example payload with fake values">
              {buildSentExample()}
            </pre>
          </Disclosure>
        </Section>

        <Section id="settings-sources" title="Sources">
          <p className="hint">
            Tokrate reads only usage numbers from the folders below. The full path stays on
            this computer; hover a folder for it.
          </p>
          <ul className="source-list">
            {sources.map((s) => (
              <SourceRow key={s.id} source={s} turns={turnsBy(s.id)} />
            ))}
          </ul>
        </Section>

        <Section id="settings-updates" title="Updates">
          <UpdatesSection />
        </Section>

        <Section id="settings-about" title="About and privacy">
          <div className="link-list">
            <button type="button" className="link-row" onClick={() => store.openHistory()}>
              Full history
              <ArrowUpRight size={16} aria-hidden="true" />
            </button>
            <button
              type="button"
              className="link-row"
              onClick={() => store.openWebsite("privacy")}
            >
              Privacy and methodology
              <ArrowUpRight size={16} aria-hidden="true" />
            </button>
            <button type="button" className="link-row" onClick={() => store.openWebsite("terms")}>
              Terms
              <ArrowUpRight size={16} aria-hidden="true" />
            </button>
          </div>
          <p className="fine">
            Local history keeps 7 days. Measurements use source-specific definitions and do not
            rate answer quality or verify provider outages. Community data refreshes at most
            every 30 seconds while sharing is on.
          </p>
          <button type="button" className="btn btn-secondary quit" onClick={() => store.quit()}>
            Quit Tokrate
          </button>
        </Section>
      </div>
    </div>
  );
}
