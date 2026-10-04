import { ArrowUpRight } from "lucide-react";
import { useStore } from "../store/store";
import { useAppStore } from "./primitives";

/** Update controls inside Settings. Checks never install; installing always needs a click. */
export function UpdatesSection() {
  const store = useAppStore();
  const update = useStore(store, (s) => s.update);
  const smoke = useStore(store, (s) => s.snapshot.smoke);
  const { preferences: prefs, available } = update;
  const mode = prefs?.mode ?? "unavailable";
  const progress =
    update.progress.total > 0
      ? Math.min(100, Math.round((update.progress.downloaded / update.progress.total) * 100))
      : null;
  const modeMessage =
    mode === "manual"
      ? "This Debian package uses manual updates. Download the signed package and install it with your package manager."
      : mode === "unavailable"
        ? "Automatic updates are available in the signed Windows installer and Linux AppImage."
        : "Update checks use Tokrate’s fixed alpha feed. Checks never install an update by themselves.";
  return (
    <div className="updates">
      <p>
        Installed version {prefs?.currentVersion ?? "unknown"}. {update.status}
      </p>
      {prefs?.settingsWarning && (
        <p role="alert" className="banner banner-danger">
          {prefs.settingsWarning}
        </p>
      )}
      {mode === "native" && !smoke && (
        <div className="switch-row">
          <p className="switch-label" id="auto-updates-label">
            Check automatically on launch and at most once every 24 hours
          </p>
          <button
            type="button"
            role="switch"
            className="switch"
            aria-checked={prefs?.automaticChecks ?? false}
            aria-labelledby="auto-updates-label"
            onClick={() => void store.setAutomaticUpdateChecks(!prefs?.automaticChecks)}
          >
            <span className="switch-thumb" />
          </button>
        </div>
      )}
      {update.checkInFlight && <p role="status">Checking for updates…</p>}
      {update.installInFlight &&
        (progress === null ? (
          <>
            <progress aria-label="Update download progress" />
            <p className="hint">Downloading the signed update…</p>
          </>
        ) : (
          <>
            <progress aria-label="Update download progress" max={100} value={progress}>
              {progress}%
            </progress>
            <p className="hint">{progress}% downloaded</p>
          </>
        ))}
      {available && (
        <div className="update-available" role="status">
          <p>
            <strong>Tokrate {available.version} is available.</strong>
            {available.body ? ` ${available.body.slice(0, 400)}` : ""}
          </p>
          <button
            type="button"
            className="btn btn-primary btn-sm"
            disabled={update.installInFlight}
            onClick={() => void store.installAvailableUpdate()}
          >
            {update.installInFlight ? "Installing update…" : "Download and install"}
          </button>
        </div>
      )}
      <p className="fine">{modeMessage}</p>
      {mode === "native" && !smoke && (
        <div className="row-actions">
          <button
            type="button"
            className="btn btn-secondary btn-sm"
            disabled={update.checkInFlight || update.installInFlight}
            onClick={() => void store.checkForUpdates(false)}
          >
            Check for updates
          </button>
        </div>
      )}
      {mode !== "native" && !smoke && (
        <div className="row-actions">
          <button
            type="button"
            className="btn btn-secondary btn-sm"
            onClick={() => store.openWebsite("desktop-downloads")}
          >
            Open desktop downloads
            <ArrowUpRight size={16} aria-hidden="true" />
          </button>
        </div>
      )}
    </div>
  );
}

/** Compact banner above the dashboard when an update has been found. */
export function UpdateBanner() {
  const store = useAppStore();
  const update = useStore(store, (s) => s.update);
  if (!update.available) return null;
  return (
    <section className="banner banner-accent update-banner" role="status">
      <div>
        <strong>Tokrate {update.available.version} is available.</strong>
        <span>Install when you’re ready. Updates never install automatically.</span>
      </div>
      <div className="banner-actions">
        <button
          type="button"
          className="btn btn-primary btn-sm"
          disabled={update.installInFlight}
          onClick={() => void store.installAvailableUpdate()}
        >
          {update.installInFlight ? "Installing…" : "Install update"}
        </button>
        <button
          type="button"
          className="btn btn-secondary btn-sm"
          onClick={() => store.openSettings("settings-updates")}
        >
          Details
        </button>
      </div>
    </section>
  );
}
