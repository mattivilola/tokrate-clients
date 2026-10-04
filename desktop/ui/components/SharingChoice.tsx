import { useEffect, useRef } from "react";
import { useStore } from "../store/store";
import { Disclosure, useAppStore } from "./primitives";

/** Obviously fake values in the exact shape of the shared allowlist (see core/src/sharing.rs). */
export function buildSentExample(): string {
  return JSON.stringify(
    {
      schemaVersion: 1,
      sentAt: "2000-01-01T00:00:00Z",
      samples: [
        {
          sampleId: "00000000-0000-0000-0000-000000000000",
          observedAt: "2000-01-01T00:05:00Z",
          client: "example-tool",
          clientVersion: "0.0.0",
          appVersion: "0.0.0",
          parserVersion: "example-parser-v0",
          metricVersion: "example-metric-v0",
          model: "example-model",
          provider: "example-provider",
          reasoningEffort: "example-effort",
          sourceKind: "example",
          outputTokens: 123,
          reasoningOutputTokens: 45,
          durationMs: 6789,
          ttftMs: null,
        },
      ],
    },
    null,
    2,
  );
}

/**
 * The sharing decision, used as onboarding step two and as the sheet opened from Settings.
 * Both buttons carry equal weight; nothing is stored, no credential store is opened and no request
 * is made until one is chosen. Polling never moves focus: only the heading is focused, once.
 */
export function SharingChoice({
  headingId,
  fromOnboarding,
}: {
  headingId: string;
  fromOnboarding: boolean;
}) {
  const store = useAppStore();
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    heading.current?.focus({ preventScroll: true });
  }, []);
  return (
    <div className="choice">
      <h1 id={headingId} tabIndex={-1} ref={heading}>
        Share your speed with the community?
      </h1>
      <p className="lede" id={`${headingId}-description`}>
        Optional. Tokrate works fully on this computer either way. If you contribute, your
        anonymous measurements join the public board at tokrate.dev.
      </p>
      <div className="share-lists">
        <div>
          <h2>Sent for each new turn</h2>
          <ul>
            <li>Coding tool, model and effort</li>
            <li>Token counts and turn duration</li>
            <li>First-token time, when available</li>
            <li>Time rounded to 5 minutes</li>
          </ul>
        </div>
        <div>
          <h2>Never sent</h2>
          <ul>
            <li>Prompts and responses</li>
            <li>Code</li>
            <li>File paths</li>
            <li>Account details</li>
          </ul>
        </div>
      </div>
      <Disclosure label="See exactly what is sent">
        <div className="details">
          <p className="detail-fine">Example with obviously fake values:</p>
          <pre className="payload" tabIndex={0} aria-label="Example payload with fake values">
            {buildSentExample()}
          </pre>
          <p className="detail-fine">
            A persistent pseudonymous signing key identifies this installation across reports.
            Its private key stays in your operating system’s secure credential store, and
            Tokrate creates or reads it only after you accept.
          </p>
          <p className="detail-fine">
            Accepting starts community requests for new measurements and community results.
            While data is early, published aggregates may be based on one contributing
            installation. Turning sharing off stops future community requests and clears queued
            reports; it does not remove reports already received. Automatic software update
            checks use their separate setting.
          </p>
          <p className="detail-fine links">
            <button type="button" className="inline-link" onClick={() => store.openWebsite("privacy")}>
              Privacy notice
            </button>
            <button type="button" className="inline-link" onClick={() => store.openWebsite("terms")}>
              Terms
            </button>
          </p>
        </div>
      </Disclosure>
      <ChoiceError />
      <div className="choice-actions">
        <button
          type="button"
          id="accept-sharing"
          className="btn btn-choice"
          onClick={() => void store.recordSharingChoice(true, fromOnboarding)}
        >
          Yes, let's contribute
        </button>
        <button
          type="button"
          id="decline-sharing"
          className="btn btn-choice"
          onClick={() => void store.recordSharingChoice(false, fromOnboarding)}
        >
          Only for local use
        </button>
      </div>
    </div>
  );
}

function ChoiceError() {
  const store = useAppStore();
  const error = useStore(store, (s) => s.error);
  return error ? (
    <p role="alert" className="banner banner-danger">
      {error}
    </p>
  ) : null;
}
