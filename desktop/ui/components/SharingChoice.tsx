import { useEffect, useRef } from "react";
import { useStore } from "../store/store";
import { Disclosure, useAppStore } from "./primitives";

/** From notice version 2: the server, not the app, derives a coarse region. */
export const REGION_NOTICE =
  "From version 0.1.14 the server derives your continent from the country of your connection when it receives a report (through Cloudflare). Only the continent is stored — not the country and not your IP address — and regions are shown publicly only with at least 3 contributors.";

/** From notice version 3: each turn also carries the output of the subagent work it started. */
export const DELEGATED_NOTICE =
  "From 0.1.16 each turn also includes the output tokens of subagent work it started (delegated output tokens), used for the efficiency indicator.";

/** From notice version 4: each turn also carries where the coding tool ran, as a category. */
export const SURFACE_NOTICE =
  "From 0.1.18 each turn also includes where the coding tool ran, as a category (command line, desktop app, editor extension, SDK or automation, other), never the app's own name.";

/** Under the same notice version 4: each turn also carries its input and prompt-cache token counts. */
export const PROMPT_CACHE_NOTICE =
  "From 0.1.18 each turn also includes its input token count and how many of those tokens were read from or written to the provider's prompt cache.";

/** What every shared turn contains, in the wording of the Mac notice. */
export const SENT_FIELDS = [
  "Coding tool, and app, parser and metric versions",
  "Model, provider (for Claude on Amazon Bedrock, its inference-profile region) and effort",
  "Source kind (primary, subagent or unknown)",
  "Token counts and turn duration",
  "Output tokens of subagent work a turn started",
  "Where the tool ran, as a category",
  "Response timing within the turn",
  "First-token time, when available",
  "Time rounded to 5 minutes",
  "A random ID for each sample",
];

/** Explains the example's fields, what the model name is, and how precisely the time is sent. */
export const FIELD_DESCRIPTION =
  "Region is derived by the server, not sent by the app. The Amazon Bedrock region (providerRegion) is the one the model id itself names and is null for every other route. Model names are sent as your coding tool reports them, so a custom deployment name is shared as is; a name with unusual characters is sent as “unknown”. Uploads leave after each five-minute period ends, so the time of a turn is not sent more precisely than its five-minute period.";

/**
 * The example upload with obviously fake values, as the shell prints it from the serializer that
 * builds real requests (`example_request_json` in core/src/sharing.rs), so it cannot drift.
 */
export function SentExample() {
  const store = useAppStore();
  const { text, failed } = useStore(store, (s) => s.sentExample);
  return (
    <pre className="payload" tabIndex={0} aria-label="Example payload with fake values">
      {text ?? (failed ? "The example could not be loaded." : "Loading the example…")}
    </pre>
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
        We measure speed, not your conversations.
      </h1>
      <p className="lede">
        Tokrate reads your local session logs to time each answer. The text stays on this
        computer. If you contribute, only the numbers are sent: which model, how many tokens,
        how many seconds.
      </p>
      <p className="lede" id={`${headingId}-description`}>
        Optional. Local monitoring and history work either way. Contributions join the public
        board at tokrate.dev.
      </p>
      <div className="share-lists">
        <div>
          <h2>Sent for each new turn</h2>
          <ul>
            {SENT_FIELDS.map((field) => (
              <li key={field}>{field}</li>
            ))}
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
      <p className="detail-fine region-notice">{SURFACE_NOTICE}</p>
      <p className="detail-fine region-notice">{PROMPT_CACHE_NOTICE}</p>
      <Disclosure label="See exactly what is sent">
        <div className="details">
          <p className="detail-fine">Example with obviously fake values:</p>
          <SentExample />
          <p className="detail-fine">{FIELD_DESCRIPTION}</p>
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
