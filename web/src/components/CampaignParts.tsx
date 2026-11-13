import type { ReactNode } from "react";
import { Badge } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import type { Journey } from "@/lib/data";

/**
 * The parts of Campaign monitoring (addition 0008v, brief N19-A part 3): a journey's status badge, its market, its
 * prerequisites count, its design link and the planned sections drawn as muted, dashed placeholders. No figures:
 * every journey is a placeholder until its monitor is built. The banner and the dashed section also draw the placeholder
 * pages of the rail (components/PlaceholderPage, 13 November 2026), so a placeholder looks the same wherever it stands.
 */

/** The Muted banner above a placeholder: it is not built yet and nothing on it is real data */
export function PlaceholderBanner({ children, testId }: { children: ReactNode; testId: string }) {
  return (
    <p role="note" className="mb-6 rounded-button border-l-4 border-p4a-muted bg-p4a-neutral-surface px-4 py-3 text-body text-p4a-muted" data-testid={testId}>
      {children}
    </p>
  );
}

/** A planned section: a dashed card with its title and its text in Muted, never a figure */
export function DashedSection({ title, children, testId, data }: { title: ReactNode; children: ReactNode; testId: string; data?: Record<`data-${string}`, string> }) {
  return (
    <section className="rounded-card border-2 border-dashed border-p4a-border bg-white p-6" data-testid={testId} {...data}>
      <h3 className="flex items-center gap-2 text-body font-semibold text-p4a-muted">{title}</h3>
      <div className="mt-2 text-small text-p4a-muted">{children}</div>
    </section>
  );
}

/** The status as a badge in words (7.5): a placeholder Neutral, being built Info, live Success */
export function JourneyStatusBadge({ status, copy }: { status: Journey["status"]; copy: Copy }) {
  const t = copy.campaigns;
  const tone = status === "live" ? "success" : status === "building" ? "info" : "neutral";
  return <span data-testid="journey-status"><Badge tone={tone}>{t[`status_${status}`]}</Badge></span>;
}

/** The market the journey covers, or all markets */
export function journeyMarket(j: Journey, copy: Copy): string {
  return j.market ? copy.campaigns.market.replace("{market}", j.market) : copy.campaigns.noMarket;
}

/** How many prerequisites the journey lists, in words */
export function prerequisitesCount(j: Journey, copy: Copy): string {
  const t = copy.campaigns;
  const n = j.prerequisites.length;
  return n === 0 ? t.prerequisitesNone : n === 1 ? t.prerequisitesOne : t.prerequisitesMany.replace("{n}", String(n));
}

/** The design's link, opened in a new tab; nothing while the journey has none */
export function DesignLink({ url, copy }: { url: string | null; copy: Copy }) {
  if (!url) return null;
  return (
    <a href={url} target="_blank" rel="noopener noreferrer" title={copy.campaigns.designHint} data-testid="journey-design"
      className="inline-flex items-center gap-1 text-small font-semibold text-p4a-deepblue hover:underline">
      {copy.campaigns.design}
      <svg aria-hidden="true" viewBox="0 0 20 20" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
        <path d="M11 3h6v6" />
        <path d="M17 3l-8 8" />
        <path d="M15 12v4a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h4" />
      </svg>
    </a>
  );
}

/** The sections a monitor will hold, in the order of the page */
export const PLANNED = ["coverage", "steps", "workflow", "attention", "drillDown", "life", "audit"] as const;
export type Planned = (typeof PLANNED)[number];

/** One planned section: a dashed card in Muted text, one line on what it will show; the drill-down is locked */
export function PlannedCard({ plan, copy }: { plan: Planned; copy: Copy }) {
  const t = copy.campaigns;
  const locked = plan === "drillDown";
  return (
    <DashedSection testId="planned-card" data={{ "data-plan": plan }}
      title={<>{locked ? <LockIcon /> : null}{t[`plan_${plan}`]}{locked ? <Badge tone="neutral">{t.locked}</Badge> : null}</>}>
      <p>{t[`plan_${plan}Text`]}</p>
    </DashedSection>
  );
}

function LockIcon(): ReactNode {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" className="h-4 w-4 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
      <rect x="4.5" y="9" width="11" height="8" rx="1.5" />
      <path d="M7 9V6.5a3 3 0 0 1 6 0V9" />
    </svg>
  );
}
