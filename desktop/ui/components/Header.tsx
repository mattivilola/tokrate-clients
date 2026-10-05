import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Check, ChevronDown, Settings as SettingsIcon } from "lucide-react";
import { client, clientLabel, measurementChip, toolLabel, type CohortRow } from "../metrics";
import { autoSelection, modelSelection } from "../response";
import type { Dashboard } from "../model/dashboard";
import { CLIENT_ORDER } from "../model/dashboard";
import { SOURCE_TITLES, PROVIDER_TITLES, effortChip, modelName } from "../model/format";
import { providerName, sortModelRows } from "../response";
import { useStore } from "../store/store";
import type { ProviderFilter, ToolFilter } from "../store/types";
import { Mark, ProviderBadge, Segmented, useAppStore, useDismiss } from "./primitives";

const TOOL_OPTIONS = [
  { value: "all", label: "All" },
  ...CLIENT_ORDER.map((id) => ({ value: id, label: SOURCE_TITLES[id] })),
] satisfies { value: ToolFilter; label: string }[];

/** "Model · effort · Subagent · v1" on one line, as shown on the picker button. */
export function cohortMenuTitle(row: CohortRow) {
  return [
    modelName(row.sample),
    effortChip(row.sample).replace(" effort", ""),
    measurementChip(row.sample),
    row.qualifier,
  ]
    .filter(Boolean)
    .join(" · ");
}

export function pickerLabel(dashboard: Dashboard) {
  const { mode } = dashboard;
  if (mode.kind === "all") return "All models";
  if (mode.kind === "auto") {
    const name = dashboard.activeKey ? (dashboard.activeKey.model ?? "Unknown model") : null;
    const prefix = mode.tool ? `Auto in ${toolLabel(mode.tool)}` : "Auto";
    return name ? `${prefix} · ${name}` : mode.tool ? prefix : "Auto (most active)";
  }
  if (mode.kind === "model") return mode.key.model ?? "Unknown model";
  const row = dashboard.cohorts.find((c) => c.key === dashboard.selectedKey);
  return row ? cohortMenuTitle(row) : "Model";
}

export function ModelPicker({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const selection = dashboard.selection;
  const toolFilter = useStore(store, (s) => s.ui.toolFilter);
  const providerFilter = useStore(store, (s) => s.ui.providerFilter);
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => setOpen(false), []);
  useDismiss(open, close, root);

  useEffect(() => {
    if (!open) return;
    // Land on the selected option so arrow keys continue from where the user is.
    const selected = root.current?.querySelector<HTMLElement>("[role=option][aria-selected=true]");
    (selected ?? root.current?.querySelector<HTMLElement>("[role=option]"))?.focus({
      preventScroll: false,
    });
  }, [open]);

  const choose = (value: string) => {
    void store.selectCohort(value);
    setOpen(false);
    trigger.current?.focus();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Escape") {
      event.stopPropagation();
      setOpen(false);
      trigger.current?.focus();
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const options = [
      ...(root.current?.querySelectorAll<HTMLElement>("[role=option]") ?? []),
    ];
    const index = options.indexOf(document.activeElement as HTMLElement);
    if (index < 0 && event.target !== trigger.current) return;
    event.preventDefault();
    const next =
      event.key === "ArrowDown"
        ? options[Math.min(options.length - 1, index + 1)]
        : options[Math.max(0, index - 1)];
    next?.focus();
  };

  const sections = CLIENT_ORDER.map((id) => ({
    id,
    rows: dashboard.cohorts.filter((c) => client(c.sample) === id),
  })).filter((s) => s.rows.length);
  const activeName = dashboard.activeKey?.model ?? null;

  return (
    <div
      className="picker"
      ref={root}
      onKeyDown={onKeyDown}
      onBlur={(event) => {
        // Tabbing out closes the popover; a null target (native select popup) keeps it open.
        const next = event.relatedTarget as Node | null;
        if (open && next && !root.current?.contains(next)) setOpen(false);
      }}
    >
      <button
        ref={trigger}
        type="button"
        className="picker-trigger"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={`Model: ${pickerLabel(dashboard)}. Change model and filters`}
        onClick={() => setOpen(!open)}
      >
        {dashboard.mode.kind !== "all" && dashboard.activeKey && (
          <ProviderBadge
            model={dashboard.activeKey.model}
            provider={dashboard.activeKey.provider}
            size={16}
          />
        )}
        <span className="picker-label">{pickerLabel(dashboard)}</span>
        <ChevronDown size={16} aria-hidden="true" className="chevron" />
      </button>
      {open && (
        <div className="popover picker-popover" role="dialog" aria-label="Choose a model">
          <div className="picker-filters">
            <Segmented
              label="Coding tool"
              size="sm"
              value={toolFilter}
              options={TOOL_OPTIONS}
              onChange={(v) => store.setToolFilter(v)}
            />
            <label className="picker-provider">
              <span>Provider route</span>
              <select
                value={providerFilter}
                onChange={(e) => store.setProviderFilter(e.target.value as ProviderFilter)}
              >
                <option value="all">All routes</option>
                {Object.entries(PROVIDER_TITLES).map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="picker-list" role="listbox" aria-label="Models">
            <PickerOption
              selected={selection === autoSelection(null)}
              onSelect={() => choose(autoSelection(null))}
              title="Auto (most active)"
              hint={
                activeName && dashboard.mode.kind === "auto" && !dashboard.mode.tool
                  ? `Follows the model you are using now · ${activeName}`
                  : "Follows the model you are using now"
              }
            />
            {dashboard.tools.length > 0 && (
              <div role="group" aria-label="Auto within a coding tool">
                <div className="picker-section">Auto within a coding tool</div>
                {dashboard.tools.map((id) => (
                  <PickerOption
                    key={id}
                    selected={selection === autoSelection(id)}
                    onSelect={() => choose(autoSelection(id))}
                    title={`Auto in ${SOURCE_TITLES[id]}`}
                  />
                ))}
              </div>
            )}
            <PickerOption
              selected={selection === "all"}
              onSelect={() => choose("all")}
              title="All models"
              hint="Compare every model side by side"
            />
            {dashboard.modelRows.length > 0 && (
              <div role="group" aria-label="Pin a model">
                <div className="picker-section">Pin a model</div>
                {sortModelRows(dashboard.modelRows, "recent").map((row) => (
                  <PickerOption
                    key={row.key}
                    selected={selection === modelSelection(row.model)}
                    onSelect={() => choose(row.key)}
                    title={[row.model.model ?? "Unknown model", providerName(row.model.provider)]
                      .filter(Boolean)
                      .join(" · ")}
                  />
                ))}
              </div>
            )}
            {sections.map((section) => (
              <div key={section.id} role="group" aria-label={SOURCE_TITLES[section.id]}>
                <div className="picker-section">
                  {clientLabel(section.rows[0].sample)} · exact cohorts
                </div>
                {section.rows.map((row) => (
                  <PickerOption
                    key={row.key}
                    selected={dashboard.mode.kind === "cohort" && dashboard.selectedKey === row.key}
                    onSelect={() => choose(row.key)}
                    title={cohortMenuTitle(row)}
                  />
                ))}
              </div>
            ))}
            {!sections.length && (
              <p className="picker-empty">No models for this filter yet.</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function PickerOption({
  selected,
  onSelect,
  title,
  hint,
}: {
  selected: boolean;
  onSelect: () => void;
  title: string;
  hint?: string;
}) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={selected}
      className="picker-option"
      onClick={onSelect}
    >
      <span className="picker-option-text">
        <span className="picker-option-title">{title}</span>
        {hint && <span className="picker-option-hint">{hint}</span>}
      </span>
      {selected && <Check size={16} aria-hidden="true" />}
    </button>
  );
}

export function Header({ dashboard }: { dashboard: Dashboard }) {
  const store = useAppStore();
  const view = useStore(store, (s) => s.ui.view);
  return (
    <header className="topbar">
      <div className="brand">
        <Mark size={28} />
        <span>Tokrate</span>
      </div>
      <ModelPicker dashboard={dashboard} />
      <button
        type="button"
        className="icon-button"
        aria-label={view === "settings" ? "Close settings" : "Open settings"}
        aria-pressed={view === "settings"}
        title="Settings"
        onClick={() => store.setView(view === "settings" ? "home" : "settings")}
      >
        <SettingsIcon size={20} aria-hidden="true" />
      </button>
    </header>
  );
}
