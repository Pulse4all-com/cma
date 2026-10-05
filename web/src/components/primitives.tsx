/**
 * Building blocks per Pulse4all-Style.md section 7. Server components unless a
 * file says otherwise; they carry no state.
 */
import type { ReactNode, ButtonHTMLAttributes } from "react";

type ButtonVariant = "primary" | "positive" | "outlined" | "text" | "destructive";
type ButtonSize = "lg" | "md" | "sm";

const variantClass: Record<ButtonVariant, string> = {
  primary: "bg-p4a-deepblue text-white hover:bg-p4a-denim",
  positive: "bg-p4a-green text-white hover:brightness-95",
  outlined: "border border-p4a-deepblue text-p4a-deepblue hover:bg-p4a-bgblue",
  text: "text-p4a-deepblue hover:underline",
  destructive: "border border-p4a-error text-p4a-error hover:bg-p4a-error-surface",
};

/* 7.2: 48px primary, 40px secondary, 32px compact; padding 24 / 16 / 12 */
const sizeClass: Record<ButtonSize, string> = {
  lg: "h-12 px-6",
  md: "h-10 px-4",
  sm: "h-8 px-3 text-small",
};

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  /** Keyboard shortcut shown as a keycap at the end of the label */
  shortcut?: string;
}

export function Button({
  variant = "primary",
  size = "md",
  shortcut,
  className = "",
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      type="button"
      className={[
        "inline-flex items-center gap-3 whitespace-nowrap rounded-button font-semibold",
        "disabled:bg-p4a-bgblue disabled:text-p4a-muted disabled:opacity-60 disabled:hover:bg-p4a-bgblue",
        variantClass[variant],
        sizeClass[size],
        className,
      ].join(" ")}
      {...rest}
    >
      <span>{children}</span>
      {shortcut ? <Keycap>{shortcut}</Keycap> : null}
    </button>
  );
}

/** Small keycap: the keyboard-first signpost, informative rather than decorative */
export function Keycap({ children }: { children: ReactNode }) {
  return (
    <kbd className="inline-flex h-5 min-w-5 items-center justify-center rounded-button border border-current/30 px-1 font-sans text-caption font-semibold leading-none opacity-80">
      {children}
    </kbd>
  );
}

/* 7.3: radius 15px, padding 24px, white with border on white pages */
export function Card({
  title,
  children,
  className = "",
}: {
  title?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={`rounded-card border border-p4a-border bg-white p-6 ${className}`}>
      {title ? <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{title}</h2> : null}
      {children}
    </section>
  );
}

type BadgeTone = "success" | "info" | "warning" | "error" | "neutral";
const badgeClass: Record<BadgeTone, string> = {
  success: "bg-p4a-success-surface text-p4a-success",
  info: "bg-p4a-bgblue text-p4a-deepblue",
  warning: "bg-p4a-warning-surface text-p4a-warning",
  error: "bg-p4a-error-surface text-p4a-error",
  neutral: "bg-p4a-neutral-surface text-p4a-muted",
};

/* 7.5: colour is never the only signal, the label is always present */
export function Badge({ tone, children }: { tone: BadgeTone; children: ReactNode }) {
  return (
    <span className={`inline-block rounded-button px-2 py-0.5 text-caption font-semibold ${badgeClass[tone]}`}>
      {children}
    </span>
  );
}

/* 2.3: calm notices; say what happened and what to do next */
export function Notice({ tone, children }: { tone: "info" | "warning"; children: ReactNode }) {
  const cls =
    tone === "warning"
      ? "border-p4a-warning bg-p4a-warning-surface"
      : "border-p4a-deepblue bg-p4a-bgblue";
  return (
    <div role="status" className={`rounded-button border-l-4 ${cls} px-4 py-3 text-body`}>
      {children}
    </div>
  );
}

/* Page title with the thin Deep Blue divider that echoes the deck header (7.1) */
export function PageTitle({ children }: { children: ReactNode }) {
  return (
    <header className="mb-6 border-b border-p4a-deepblue pb-3">
      <h1 className="text-title font-bold text-p4a-heading">{children}</h1>
    </header>
  );
}
