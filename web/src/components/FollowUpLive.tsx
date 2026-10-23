/**
 * The Live board's follow-up strip (addition 0008o): six tiles under the inbound ones, from
 * cma.follow_up_summary: leads not called and past the target, tickets at risk and over their response
 * time, tasks overdue and due today. Counts only; the Follow-up report has the rows. Tiles as InboundLive's
 * (docs/style/Pulse4all-Style.md 7.3), each with its hint, no figure a filled red tile. A server component:
 * the page's poll (LiveRefresh) reads it again every 10 seconds.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { FollowUpSummary } from "@/lib/data";
import { FOLLOW_UP_TILES, type FollowUpTileKey } from "@/lib/follow-up";
import { fillHint, fmtCount } from "@/lib/reports";
import { HeaderHint } from "./HeaderHint";

export function FollowUpLive({ summary, copy, locale, targetMinutes, warningPct, moreOf }: {
  summary: FollowUpSummary; copy: Copy; locale: Locale; targetMinutes: number | null; warningPct: number | null;
  /** "How this is computed" per tile, to the figure's catalog entry; given only for tenant.configure */
  moreOf?: (key: FollowUpTileKey) => { href: string; label: string } | undefined;
}) {
  const t = copy.followUp;
  const h = copy.hints;
  const labels: Record<FollowUpTileKey, { label: string; hint: string }> = {
    leadsOpenNotCalled: { label: t.tileLeadsOpen, hint: h.fuLeadsOpen },
    leadsPastTarget: { label: t.tileLeadsPast, hint: h.fuLeadsPast },
    ticketsAtRisk: { label: t.tileTicketsAtRisk, hint: h.fuTicketsAtRisk },
    ticketsBreached: { label: t.tileTicketsBreached, hint: h.fuTicketsBreached },
    tasksOverdue: { label: t.tileTasksOverdue, hint: h.fuTasksOverdue },
    tasksDueToday: { label: t.tileTasksToday, hint: h.fuTasksToday },
  };
  return (
    <section aria-labelledby="follow-up-now" className="flex flex-col gap-4" data-testid="follow-up-live">
      <div className="flex items-baseline justify-between gap-4">
        <h2 id="follow-up-now" className="text-panel font-semibold text-p4a-heading">{copy.live.followUpTitle}</h2>
        {/* no prefetch: this card sits on a polled page and would fetch the route again on every refresh (Shell) */}
        <Link href="/reports/follow-up" prefetch={false} className="text-small font-semibold text-p4a-deepblue hover:underline">{copy.live.openFollowUp}</Link>
      </div>
      <div className="grid grid-cols-3 gap-4 2xl:grid-cols-6" data-testid="follow-up-tiles">
        {FOLLOW_UP_TILES.map((key) => (
          <div key={key} className="rounded-card border border-p4a-border bg-white p-6" data-testid={`follow-up-${key}`} data-tile="">
            <p className="flex items-start text-small text-p4a-muted" data-hint-anchor="">
              {labels[key].label}
              <HeaderHint label={h.about.replace("{label}", labels[key].label)} text={fillHint(labels[key].hint, { hours: h.officeHours, target: targetMinutes, warning: warningPct }, locale)} more={moreOf?.(key)} />
            </p>
            <div className="tabular mt-1 whitespace-nowrap text-title font-bold text-p4a-heading">{fmtCount(summary[key], locale)}</div>
          </div>
        ))}
      </div>
    </section>
  );
}
