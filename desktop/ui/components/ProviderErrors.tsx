import { CircleAlert, CircleCheck, Info } from "lucide-react";
import {
  communityErrorLine,
  providerErrorLine,
  SHARING_HINT,
} from "../model/provider-errors";
import { useStore } from "../store/store";
import { useAppStore } from "./primitives";

/**
 * Passive lines about provider-side failures: the user's own of the last 24 hours, and under them
 * what other contributors report (or, with sharing off, a hint to turn sharing on), with a way to
 * be notified while that setting is off. Hidden when there is nothing to say.
 */
export function ProviderErrors() {
  const store = useAppStore();
  const snapshot = useStore(store, (s) => s.snapshot);
  const recovery = useStore(store, (s) => s.errorRecovery);
  const now = useStore(store, (s) => s.now);
  const { sharing, errorNotifications } = snapshot.settings;
  const local = providerErrorLine(snapshot.providerErrors, now);
  const community = communityErrorLine(
    { relevant: snapshot.relevantErrorAlerts, sharing, now },
    recovery,
  );
  const hint = local && !sharing ? SHARING_HINT : null;
  if (!local && !community && !hint) return null;
  return (
    <div className="provider-errors-group">
      {local && (
        <p className="provider-errors" role="note">
          <CircleAlert size={16} aria-hidden="true" />
          <span>{local}</span>
        </p>
      )}
      {community && (
        <p
          className={`provider-errors${community.kind === "recovery" ? " provider-errors-quiet" : ""}`}
          role="note"
        >
          {community.kind === "recovery" ? (
            <CircleCheck size={16} aria-hidden="true" />
          ) : (
            <CircleAlert size={16} aria-hidden="true" />
          )}
          <span>{community.text}</span>
          {community.kind === "alert" && !errorNotifications && (
            <button
              type="button"
              className="text-button"
              onClick={() => void store.patch({ errorNotifications: true })}
            >
              Notify me
            </button>
          )}
        </p>
      )}
      {hint && (
        <p className="provider-errors provider-errors-quiet" role="note">
          <Info size={16} aria-hidden="true" />
          <span>{hint}</span>
        </p>
      )}
    </div>
  );
}
