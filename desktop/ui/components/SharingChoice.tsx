import { useEffect, useRef } from "react";
import { useStore } from "../store/store";
import { Disclosure, useAppStore } from "./primitives";

/** From notice version 2: the server, not the app, derives a coarse region. */
export const REGION_NOTICE =
  "From version 0.1.14 the server derives your continent from the country of your connection when it receives a report (through Cloudflare). Only the continent is stored — not the country and not your IP address — and regions are shown publicly only with at least 3 contributors.";

/** From notice version 3: each turn also carries the output of the subagent work it started. */
export const DELEGATED_NOTICE =
  "From 0.1.16 each turn also includes the output tokens of subagent work it started (delegated output tokens), used for the efficiency indicator.";

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
          providerRegion: null,
          reasoningEffort: "example-effort",
          sourceKind: "example",
          outputTokens: 123,
          reasoningOutputTokens: 45,
          durationMs: 6789,
          ttftMs: null,
          responseOutputTokens: 100,
          responseDurationMs: 4321,
          responseCount: 2,
          delegatedOutputTokens: 0,
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
            <li>Output tokens of subagent work a turn started</li>
            <li>Response timing within the turn</li>
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
      <p className="detail-fine region-notice">{REGION_NOTICE}</p>
      <p className="detail-fine region-notice">{DELEGATED_NOTICE}</p>
      <Disclosure label="See exactly what is sent">
        <div className="details">
          <p className="detail-fine">Example with obviously fake values:</p>
          <pre className="payload" tabIndex={0} aria-label="Example payload with fake values">
            {buildSentExample()}
          </pre>
          <p className="detail-fine">
            Region is derived by the server, not sent by the app. The Amazon Bedrock region
            (providerRegion) is the one the model id itself names and is null for every other
            route.
          </p>
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
