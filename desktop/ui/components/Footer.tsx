import { ArrowUpRight } from "lucide-react";
import { monitoringState, sharingState } from "../model/status";
import { useStore } from "../store/store";
import { StatusDot, useAppStore } from "./primitives";

export function Footer() {
  const store = useAppStore();
  const snapshot = useStore(store, (s) => s.snapshot);
  const monitoring = monitoringState(snapshot);
  const sharing = sharingState(snapshot);
  return (
    <footer className="statusbar">
      <p className="status-items">
        <span className="status-item" title={snapshot.monitorStatus}>
          <StatusDot tone={monitoring.tone} />
          {monitoring.label}
        </span>
        <span className="status-item" title={snapshot.status}>
          <StatusDot tone={sharing.tone} />
          {sharing.label}
        </span>
      </p>
      <button
        type="button"
        className="text-button"
        title="Open tokrate.dev in your browser"
        onClick={() => store.openWebsite("home")}
      >
        Open tokrate.dev
        <ArrowUpRight size={16} aria-hidden="true" />
      </button>
    </footer>
  );
}
