import type { ReactNode } from "react";
import { Badge } from "@/components/primitives";
import type { Copy } from "@/lib/copy";
import type { Journey } from "@/lib/data";

/**
 * The parts of Campaign monitoring (addition 0008v, brief N19-A part 3): a journey's status badge, its market, its
 * prerequisites count, its design link and the planned sections drawn as muted, dashed placeholders. No figures:
 * every journey is a placeholder until its monitor is built.
 */

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
    <section className="rounded-card border-2 border-dashed border-p4a-border bg-white p-6" data-testid="planned-card" data-plan={plan}>
      <h3 className="flex items-center gap-2 text-body font-semibold text-p4a-muted">
        {locked ? <LockIcon /> : null}
        {t[`plan_${plan}`]}
        {locked ? <Badge tone="neutral">{t.locked}</Badge> : null}
      </h3>
      <p className="mt-2 text-small text-p4a-muted">{t[`plan_${plan}Text`]}</p>
    </section>
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
