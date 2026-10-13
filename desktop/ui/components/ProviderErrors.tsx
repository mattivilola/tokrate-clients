import { CircleAlert } from "lucide-react";
import { providerErrorLine } from "../model/provider-errors";
import { useStore } from "../store/store";
import { useAppStore } from "./primitives";

/** Passive line about the user's own provider-side failures; hidden without one in 24 hours. */
export function ProviderErrors() {
  const store = useAppStore();
  const groups = useStore(store, (s) => s.snapshot.providerErrors);
  const now = useStore(store, (s) => s.now);
  const line = providerErrorLine(groups, now);
  if (!line) return null;
  return (
    <p className="provider-errors" role="note">
      <CircleAlert size={16} aria-hidden="true" />
      <span>{line}</span>
    </p>
  );
}
