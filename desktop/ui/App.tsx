import { useEffect } from "react";
import { X } from "lucide-react";
import { client } from "./metrics";
import { useDashboard } from "./model/use-dashboard";
import { useStore, type AppStore } from "./store/store";
import { Community } from "./components/Community";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { ConsentSheet } from "./components/ConsentSheet";
import { Footer } from "./components/Footer";
import { Header } from "./components/Header";
import { Hero } from "./components/Hero";
import { HistoryView } from "./components/History";
import { CompareAll, YourModels } from "./components/Models";
import { Onboarding } from "./components/Onboarding";
import { StoreContext, useAppStore } from "./components/primitives";
import { SettingsView } from "./components/Settings";
import { Trend } from "./components/Trend";
import { UpdateBanner } from "./components/Updates";

export type WindowKind = "flyout" | "history";

function Notices({ updates = true }: { updates?: boolean }) {
  const store = useAppStore();
  const error = useStore(store, (s) => s.error);
  return (
    <>
      {!store.bridge.native && (
        <p className="banner banner-warn" role="note">
          Development preview · synthetic local data · no network sharing
        </p>
      )}
      {updates && <UpdateBanner />}
      {error && (
        <p role="alert" className="banner banner-danger">
          <span>{error}</span>
          <button
            type="button"
            className="icon-button icon-button-sm"
            aria-label="Dismiss message"
            onClick={store.dismissError}
          >
            <X size={16} aria-hidden="true" />
          </button>
        </p>
      )}
    </>
  );
}

/** Shown in place of the community card when it cannot be drawn (the board is data from a server). */
export function CommunityUnavailable() {
  return (
    <section className="card community" aria-label="Community">
      <p className="detail-fine" role="status">
        Community data unavailable
      </p>
    </section>
  );
}

function DataUnavailable() {
  return (
    <section className="card" aria-label="Measurements">
      <p className="detail-fine" role="status">
        These measurements could not be shown.
      </p>
    </section>
  );
}

function Home() {
  const store = useAppStore();
  const dashboard = useDashboard(store);
  const board = useStore(store, (s) => s.snapshot.board);
  const revision = useStore(store, (s) => s.snapshot.revision);
  return (
    <>
      <Header dashboard={dashboard} />
      <Notices />
      <main className="scroll home-scroll">
        <ErrorBoundary fallback={<DataUnavailable />} resetKey={revision}>
          {dashboard.isAll ? (
            <CompareAll dashboard={dashboard} board={board} />
          ) : (
            <>
              <Hero dashboard={dashboard} />
              <Trend dashboard={dashboard} />
              <YourModels dashboard={dashboard} />
            </>
          )}
        </ErrorBoundary>
        <ErrorBoundary fallback={<CommunityUnavailable />} resetKey={board}>
          <Community dashboard={dashboard} />
        </ErrorBoundary>
      </main>
      <Footer />
    </>
  );
}

function History() {
  const store = useAppStore();
  const dashboard = useDashboard(store);
  return (
    <>
      <Notices updates={false} />
      <HistoryView dashboard={dashboard} />
    </>
  );
}

/** Native smoke mode: assert the parsed fixtures reached the rendered dashboard, then exit. */
function SmokeProbe() {
  const store = useAppStore();
  const snapshot = useStore(store, (s) => s.snapshot);
  useEffect(() => {
    if (!snapshot.smoke) return;
    const find = (tool: string, model: string) =>
      snapshot.records.find((m) => client(m) === tool && m.model === model);
    const codex = find("codex", "fixture-model");
    const claude = find("claude-code", "claude-fixture-model");
    const grok = find("grok-build", "grok-fixture-model");
    if (!codex || !claude || !grok) return;
    const near = (actual: number, expected: number) => Math.abs(actual - expected) < 0.000001;
    if (
      !near(codex.turnThroughputTPS, 20) ||
      !near(claude.turnThroughputTPS, 30) ||
      !near(grok.turnThroughputTPS, 24) ||
      claude.codexTTFTSeconds !== null ||
      grok.codexTTFTSeconds !== null ||
      !document.querySelector(".gauge") ||
      snapshot.settings.sharing
    )
      throw new Error("Smoke source metrics assertion");
    void store.smokeComplete();
  }, [snapshot, store]);
  return null;
}

/** Last resort when a whole view fails to render: the way to settings and to a retry stays. */
function WindowFailed({ retry, kind }: { retry: () => void; kind: WindowKind }) {
  const store = useAppStore();
  return (
    <main className="scroll home-scroll">
      <section className="card" role="alert">
        <p className="detail-fine">Something could not be shown.</p>
        <p className="links">
          <button type="button" className="inline-link" onClick={retry}>
            Try again
          </button>
          {kind === "flyout" && (
            <button
              type="button"
              className="inline-link"
              onClick={() => {
                store.openSettings();
                retry();
              }}
            >
              Open settings
            </button>
          )}
        </p>
      </section>
    </main>
  );
}

export function App({ store, kind }: { store: AppStore; kind: WindowKind }) {
  useEffect(() => store.start(), [store]);
  const view = useStore(store, (s) => s.ui.view);
  const consentPending = useStore(store, (s) => s.snapshot.consentPromptRequired);
  const onboardingStep = useStore(store, (s) => s.ui.onboardingStep);
  const sheetOpen = useStore(store, (s) => s.ui.consentSheetOpen);
  const ready = useStore(store, (s) => s.loaded || s.error !== "");
  const onboarding = kind === "flyout" && (consentPending || onboardingStep === 2);

  // Escape steps back (settings to dashboard), then hides the flyout. Popovers consume their own Escape.
  useEffect(() => {
    if (kind !== "flyout") return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (store.getState().ui.view === "settings") store.setView("home");
      else store.hideFlyout();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [kind, store]);

  return (
    <StoreContext.Provider value={store}>
      <div className={`app-shell ${kind === "history" ? "window-history" : "window-flyout"}`}>
        <ErrorBoundary fallback={(retry) => <WindowFailed retry={retry} kind={kind} />}>
          {!ready ? null : kind === "history" ? (
            <History />
          ) : onboarding ? (
            <>
              <Notices />
              <Onboarding />
            </>
          ) : view === "settings" ? (
            <SettingsView />
          ) : (
            <Home />
          )}
        </ErrorBoundary>
        {sheetOpen && !onboarding && <ConsentSheet />}
        <SmokeProbe />
      </div>
    </StoreContext.Provider>
  );
}
