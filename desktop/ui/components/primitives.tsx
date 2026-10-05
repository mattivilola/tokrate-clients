import {
  createContext,
  useContext,
  useEffect,
  useId,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { ChevronDown, Info } from "lucide-react";
import { BADGE_LABEL, BADGE_LETTER, badgeFamily } from "../response";
import { useStore, type AppStore } from "../store/store";

export const StoreContext = createContext<AppStore | null>(null);
export function useAppStore(): AppStore {
  const store = useContext(StoreContext);
  if (!store) throw new Error("StoreContext is missing");
  return store;
}

/** The brand mark from docs/design-language.md. */
export function Mark({ size = 28 }: { size?: number }) {
  const id = useId();
  return (
    <svg
      className="mark"
      width={size}
      height={size}
      viewBox="0 0 48 48"
      aria-hidden="true"
    >
      <defs>
        <linearGradient id={id} x1="0" x2="1">
          <stop offset="0" stopColor="#1E9BB5" />
          <stop offset="1" stopColor="#3CCFB4" />
        </linearGradient>
      </defs>
      <rect width="48" height="48" rx="12" fill="#0B2530" />
      <path
        d="M11.9 33A14 14 0 1 1 36.1 33"
        fill="none"
        stroke={`url(#${id})`}
        strokeWidth="4"
        strokeLinecap="round"
      />
      <path
        d="M24 26 31.1 18.9"
        stroke="#FF6B4A"
        strokeWidth="3.5"
        strokeLinecap="round"
      />
      <circle cx="24" cy="26" r="2.8" fill="#FF6B4A" />
    </svg>
  );
}

/**
 * Filled circle with a white letter for the model's provider: A Anthropic, O OpenAI, X xAI, a
 * plain grey dot when unknown. Letters only, no logos. Hidden when "Show provider badge" is off.
 */
export function ProviderBadge({
  model,
  provider,
  size = 18,
}: {
  model: string | null | undefined;
  provider: string | null | undefined;
  size?: number;
}) {
  const store = useAppStore();
  const enabled = useStore(store, (s) => s.snapshot.settings.showProviderBadge !== false);
  if (!enabled) return null;
  const family = badgeFamily(model, provider);
  const letter = BADGE_LETTER[family];
  return (
    <svg
      className={`provider-badge badge-${family}`}
      width={size}
      height={size}
      viewBox="0 0 20 20"
      role="img"
      aria-label={BADGE_LABEL[family]}
    >
      <title>{BADGE_LABEL[family]}</title>
      <circle cx="10" cy="10" r="10" className="badge-disc" />
      {letter && (
        <text x="10" y="14.2" textAnchor="middle" className="badge-letter">
          {letter}
        </text>
      )}
    </svg>
  );
}

export function Chip({
  children,
  tone = "neutral",
  title,
}: {
  children: ReactNode;
  tone?: "neutral" | "accent" | "warn";
  title?: string;
}) {
  return (
    <span className={`chip chip-${tone}`} title={title}>
      {children}
    </span>
  );
}

export interface SegmentOption<T extends string> {
  value: T;
  label: string;
  disabled?: boolean;
  title?: string;
}

/** Radio-group segmented control; arrow keys move the selection like native radios. */
export function Segmented<T extends string>({
  label,
  value,
  options,
  onChange,
  size = "md",
}: {
  label: string;
  value: T;
  options: SegmentOption<T>[];
  onChange: (value: T) => void;
  size?: "sm" | "md";
}) {
  const move = (event: KeyboardEvent<HTMLDivElement>) => {
    const enabled = options.filter((o) => !o.disabled);
    const index = enabled.findIndex((o) => o.value === value);
    const step =
      event.key === "ArrowRight" || event.key === "ArrowDown"
        ? 1
        : event.key === "ArrowLeft" || event.key === "ArrowUp"
          ? -1
          : 0;
    if (!step || index < 0) return;
    event.preventDefault();
    const next = enabled[(index + step + enabled.length) % enabled.length];
    onChange(next.value);
    const buttons =
      event.currentTarget.querySelectorAll<HTMLButtonElement>("button");
    buttons[options.indexOf(next)]?.focus();
  };
  return (
    <div
      className={`segmented segmented-${size}`}
      role="radiogroup"
      aria-label={label}
      onKeyDown={move}
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="radio"
          aria-checked={option.value === value}
          aria-disabled={option.disabled || undefined}
          tabIndex={option.value === value ? 0 : -1}
          title={option.title}
          className="segment"
          onClick={() => !option.disabled && onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

export function Switch({
  checked,
  onChange,
  label,
  describedBy,
  disabled,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  label: string;
  describedBy?: string;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      aria-describedby={describedBy}
      disabled={disabled}
      className="switch"
      onClick={() => onChange(!checked)}
    >
      <span className="switch-thumb" />
    </button>
  );
}

/** Inline expandable region. Content stays mounted-on-demand; state lives with the caller or locally. */
export function Disclosure({
  label,
  children,
  defaultOpen = false,
  className = "",
}: {
  label: ReactNode;
  children: ReactNode;
  defaultOpen?: boolean;
  className?: string;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const id = useId();
  return (
    <div className={`disclosure ${className}`} data-open={open}>
      <button
        type="button"
        className="disclosure-trigger"
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen(!open)}
      >
        <span>{label}</span>
        <ChevronDown size={16} aria-hidden="true" className="chevron" />
      </button>
      {open && (
        <div className="disclosure-body" id={id}>
          {children}
        </div>
      )}
    </div>
  );
}

/** The single ⓘ affordance that holds the longer caveats behind a number. */
export function InfoDisclosure({
  label = "About this number",
  children,
}: {
  label?: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  return (
    <span className="info">
      <button
        type="button"
        className="icon-button icon-button-sm"
        aria-label={label}
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen(!open)}
      >
        <Info size={16} aria-hidden="true" />
      </button>
      {open && (
        <span className="info-body" id={id} role="note">
          {children}
        </span>
      )}
    </span>
  );
}

/** Closes on Escape and outside pointer; returns focus to the trigger. */
export function useDismiss(
  open: boolean,
  close: () => void,
  containerRef: React.RefObject<HTMLElement | null>,
) {
  useEffect(() => {
    if (!open) return;
    const onPointer = (event: PointerEvent) => {
      if (!containerRef.current?.contains(event.target as Node)) close();
    };
    document.addEventListener("pointerdown", onPointer);
    return () => document.removeEventListener("pointerdown", onPointer);
  }, [open, close, containerRef]);
}

export function StatusDot({
  tone,
}: {
  tone: "good" | "warn" | "muted" | "danger";
}) {
  return <span className={`dot dot-${tone}`} aria-hidden="true" />;
}
