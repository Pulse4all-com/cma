/**
 * The Live board's figure panels (the Live board's UX pass, 10 November 2026): one card per part of the board (Inbound
 * today, Outbound today, Follow-up now, the team's groups), its title and caption on one line, then its figures in one
 * row of six columns divided by hairlines, at every width from the design width (1280 px) on. Six cards of the same
 * figures took two rows each at 1280 px; one panel each puts every figure of the board on the first screen. The columns
 * line up from panel to panel, so Inbound today's Talk time sits above Outbound today's. Cards per
 * docs/style/Pulse4all-Style.md 7.3 (radius 15px, padding 24px, white with the border), dividers per 7.1, the title an
 * h4 (18px Semi Bold Deep Blue), the dense scale of 3.3 (labels 13px Muted, figures 24px Bold Deep Blue in tabular
 * figures, as the tiles before: a figure that changes with every poll keeps its width). A label wraps, and a long Dutch word is hyphenated in its
 * language ("Verbindingspercentage"), never cut off. The data-testid and data-tile hooks are the tiles' before
 * (verify:layout, verify:live).
 */
import type { ReactNode } from "react";
import type { Locale } from "@/lib/copy";
import { HeaderHint } from "./HeaderHint";

export function StatPanel({ id, title, scope, scopeTestId, action, testId, figuresTestId, children }: {
  /** The heading's id, for the section's name */
  id: string;
  title: string;
  /** A caption after the title on what the figures cover (a contact center's board: all its counted lines, the whole business line) */
  scope?: string;
  scopeTestId?: string;
  /** A link at the right of the title row (Follow-up now's "Open Follow-up") */
  action?: ReactNode;
  testId: string;
  figuresTestId: string;
  children: ReactNode;
}) {
  return (
    <section aria-labelledby={id} className="rounded-card border border-p4a-border bg-white p-6" data-testid={testId}>
      <div className="mb-4 flex items-baseline justify-between gap-4">
        <div className="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 id={id} className="text-panel font-semibold text-p4a-heading">{title}</h2>
          {scope ? <p className="text-small text-p4a-muted" data-testid={scopeTestId}>{scope}</p> : null}
        </div>
        {action}
      </div>
      <div className="grid grid-cols-6 divide-x divide-p4a-border" data-testid={figuresTestId}>
        {children}
      </div>
    </section>
  );
}

/** One figure of a panel: its label with the hint behind the info mark, then the value */
export function Stat({ label, info, value, testId, locale }: {
  label: string;
  /** The hint behind the info mark; more: "How this is computed" to the figure's catalog entry, for tenant.configure only */
  info: { about: string; text: string; more?: { href: string; label: string } };
  value: ReactNode;
  testId: string;
  /** The label's language, so a long word breaks where the language breaks it */
  locale: Locale;
}) {
  return (
    <div className="flex min-w-0 flex-col px-4 first:pl-0 last:pr-0" data-testid={testId} data-tile="">
      <p lang={locale} className="flex items-start text-small text-p4a-muted [overflow-wrap:anywhere] hyphens-auto" data-hint-anchor="">
        <span className="min-w-0">{label}</span>
        <HeaderHint label={info.about} text={info.text} more={info.more} />
      </p>
      {/* at the cell's foot, so the figures of a row line up when a label takes two lines */}
      {/* tabular figures, as the tiles before: a figure that changes every poll keeps its width */}
      <div className="tabular mt-auto whitespace-nowrap pt-1 text-title font-bold text-p4a-heading">{value}</div>
    </div>
  );
}
