import { useEffect, useRef, useState } from "react";
import { X } from "lucide-react";
import { useAppStore } from "./primitives";
import { SharingChoice } from "./SharingChoice";

/**
 * The sharing notice opened from Settings. Closing it (Escape, the close button or the backdrop)
 * keeps sharing off. The page behind is inert and Tab stays inside the dialog.
 */
export function ConsentSheet() {
  const store = useAppStore();
  const card = useRef<HTMLElement>(null);
  // Captured while rendering: child effects focus the heading before this component's effect runs.
  const [opener] = useState(() => document.activeElement);

  useEffect(() => {
    const siblings = [
      ...document.querySelectorAll<HTMLElement>(".app-shell > :not(.sheet-backdrop)"),
    ];
    siblings.forEach((el) => (el.inert = true));
    return () => {
      siblings.forEach((el) => (el.inert = false));
      (opener as HTMLElement | null)?.focus?.({ preventScroll: true });
    };
  }, []);

  const close = () => store.setConsentSheet(false);
  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.stopPropagation();
      close();
      return;
    }
    if (event.key !== "Tab") return;
    const controls = [
      ...(card.current?.querySelectorAll<HTMLElement>(
        "a[href], button:not(:disabled), select, [tabindex]:not([tabindex='-1'])",
      ) ?? []),
    ];
    const first = controls[0];
    const last = controls[controls.length - 1];
    const active = document.activeElement;
    const onHeading = active?.id === "sheet-sharing";
    if (event.shiftKey && (active === first || onHeading)) {
      event.preventDefault();
      last?.focus();
    } else if (!event.shiftKey && active === last) {
      event.preventDefault();
      first?.focus();
    }
  };

  return (
    <div className="sheet-backdrop" onKeyDown={onKeyDown}>
      <section
        ref={card}
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="sheet-sharing"
        aria-describedby="sheet-sharing-description"
      >
        <button
          type="button"
          className="icon-button sheet-close"
          aria-label="Close without sharing"
          onClick={close}
        >
          <X size={20} aria-hidden="true" />
        </button>
        <div className="scroll">
          <SharingChoice headingId="sheet-sharing" fromOnboarding={false} />
        </div>
      </section>
    </div>
  );
}
