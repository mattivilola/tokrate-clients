import { useEffect, useRef, type ReactNode } from "react";
import { Check, Minus } from "lucide-react";
import { SOURCE_TITLES } from "../model/format";
import { useStore } from "../store/store";
import type { SourceStatus } from "../store/types";
import { Mark, useAppStore } from "./primitives";
import { SharingChoice } from "./SharingChoice";

const STEP_TITLES = ["Welcome", "Sharing", "Find Tokrate"];

function Steps({ step }: { step: number }) {
  return (
    <ol className="steps" aria-label={`Step ${step + 1} of 3: ${STEP_TITLES[step]}`}>
      {STEP_TITLES.map((title, i) => (
        <li key={title} data-state={i === step ? "current" : i < step ? "done" : "todo"} aria-current={i === step ? "step" : undefined}>
          <span className="visually-hidden">{title}</span>
        </li>
      ))}
    </ol>
  );
}

function Step({ children }: { children: ReactNode }) {
  return <div className="onboarding-step">{children}</div>;
}

function SourceStatusRow({ source }: { source: SourceStatus }) {
  return (
    <li className="detected" data-found={source.found}>
      <span className="detected-icon" aria-hidden="true">
        {source.found ? <Check size={16} /> : <Minus size={16} />}
      </span>
      <span className="detected-name">{SOURCE_TITLES[source.id]}</span>
      <span className="detected-state">{source.found ? "Found" : "Not found"}</span>
    </li>
  );
}

function Welcome() {
  const store = useAppStore();
  const sources = useStore(store, (s) => s.snapshot.sources) ?? [];
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus({ preventScroll: true }), []);
  const found = sources.filter((s) => s.found).length;
  return (
    <Step>
      <div className="welcome-mark">
        <Mark size={56} />
      </div>
      <h1 id="onboarding-welcome" tabIndex={-1} ref={heading}>
        Welcome to Tokrate
      </h1>
      <p className="lede">
        See how fast your coding model is right now, and which one is fastest. Tokrate reads
        timing and token counts from the session files your coding tools write on this computer.
        Prompts, responses and code are never retained, and nothing leaves this computer unless
        you choose to share.
      </p>
      <h2 className="eyebrow">Detected on this computer</h2>
      <ul className="detected-list">
        {sources.map((s) => (
          <SourceStatusRow key={s.id} source={s} />
        ))}
      </ul>
      <p className="hint">
        {sources.length && found === 0
          ? "No coding tool folders found yet. You can choose folders later in Settings, and Tokrate starts measuring as soon as a turn completes."
          : "Missing a tool? Choose its folder later in Settings."}
      </p>
      <div className="onboarding-actions">
        <button type="button" className="btn btn-primary" onClick={() => store.setOnboardingStep(1)}>
          Continue
        </button>
      </div>
    </Step>
  );
}

function Finish() {
  const store = useAppStore();
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => heading.current?.focus({ preventScroll: true }), []);
  return (
    <Step>
      <div className="tray-art" aria-hidden="true">
        <svg viewBox="0 0 280 64" width="100%">
          <rect x="1" y="1" width="278" height="62" rx="12" className="tray-art-bar" />
          <circle cx="92" cy="32" r="3" className="tray-art-dot" />
          <circle cx="112" cy="32" r="3" className="tray-art-dot" />
          <circle cx="132" cy="32" r="3" className="tray-art-dot" />
          <circle cx="248" cy="32" r="3" className="tray-art-dot" />
          <rect x="170" y="10" width="44" height="44" rx="11" className="tray-art-focus" />
          <g transform="translate(176 16) scale(0.667)">
            <rect width="48" height="48" rx="12" fill="#0B2530" />
            <path d="M11.9 33A14 14 0 1 1 36.1 33" fill="none" stroke="#3CCFB4" strokeWidth="4" strokeLinecap="round" />
            <path d="M24 26 31.1 18.9" stroke="#FF6B4A" strokeWidth="3.5" strokeLinecap="round" />
            <circle cx="24" cy="26" r="2.8" fill="#FF6B4A" />
          </g>
          <circle cx="228" cy="32" r="3" className="tray-art-dot" />
        </svg>
      </div>
      <h1 id="onboarding-finish" tabIndex={-1} ref={heading}>
        Find Tokrate in your tray
      </h1>
      <p className="lede">
        Tokrate keeps running quietly in your system tray, near the clock. Click its icon to open
        this view, or right-click for the menu.
      </p>
      <p className="hint">
        On some Linux desktops the tray icon sits in a panel or behind a menu. Closing this
        window never quits Tokrate; use Quit in Settings or the tray menu.
      </p>
      <div className="onboarding-actions">
        <button
          type="button"
          className="btn btn-primary"
          onClick={() => {
            store.setOnboardingStep(0);
            store.hideFlyout();
          }}
        >
          Done
        </button>
      </div>
    </Step>
  );
}

/** First launch: welcome with detected sources, the sharing choice, and where to find Tokrate. */
export function Onboarding() {
  const store = useAppStore();
  const step = useStore(store, (s) => s.ui.onboardingStep);
  return (
    <div className="onboarding">
      <div className="onboarding-top">
        <Steps step={step} />
      </div>
      <div className="scroll onboarding-scroll">
        {step === 0 && <Welcome />}
        {step === 1 && (
          <Step>
            <SharingChoice headingId="onboarding-sharing" fromOnboarding />
            <div className="onboarding-back">
              <button type="button" className="text-button" onClick={() => store.setOnboardingStep(0)}>
                Back
              </button>
            </div>
          </Step>
        )}
        {step === 2 && <Finish />}
      </div>
    </div>
  );
}
