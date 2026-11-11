/**
 * The Live board's follow-up strip (addition 0008o): six figures under the call panels, from
 * cma.follow_up_summary: leads not called and past the target, tickets at risk and over their response
 * time, tasks overdue and due today. Counts only; the Follow-up report has the rows. One panel of six figures as the call
 * panels (StatPanel, the Live board's UX pass of 10 November 2026; docs/style/Pulse4all-Style.md 7.3), each with its hint,
 * no figure a filled red tile. Rendered by the board's poll (LiveBoardLive), which reads it again every 10 seconds. On a contact center's board (addition 0008zv) a caption
 * under the title says the counts cover the whole business line (Martin, 5 November 2026).
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { FollowUpSummary } from "@/lib/data";
import { FOLLOW_UP_TILES, type FollowUpTileKey } from "@/lib/follow-up";
import type { LiveFollowUpWords, LiveHints } from "@/lib/live";
import { fillHint, fmtCount } from "@/lib/reports";
import { Stat, StatPanel } from "./StatPanel";

export function FollowUpLive({ summary, copy, locale, targetMinutes, warningPct, moreOf, scope }: {
  summary: FollowUpSummary; copy: Pick<Copy, "live"> & { hints: LiveHints; followUp: LiveFollowUpWords }; locale: Locale; targetMinutes: number | null; warningPct: number | null;
  /** "How this is computed" per tile, to the figure's catalog entry; given only for tenant.configure */
  moreOf?: (key: FollowUpTileKey) => { href: string; label: string } | undefined;
  /** A caption under the title on what the counts cover (a contact center's board: the whole business line) */
  scope?: string;
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
    <StatPanel id="follow-up-now" title={copy.live.followUpTitle} scope={scope} scopeTestId="follow-up-scope" testId="follow-up-live" figuresTestId="follow-up-tiles"
      // no prefetch: this card sits on a polled page and would fetch the route again on every refresh (Shell)
      action={<Link href="/reports/follow-up" prefetch={false} className="shrink-0 text-small font-semibold text-p4a-deepblue hover:underline">{copy.live.openFollowUp}</Link>}>
      {FOLLOW_UP_TILES.map((key) => (
        <Stat key={key} testId={`follow-up-${key}`} label={labels[key].label} locale={locale} value={fmtCount(summary[key], locale)}
          info={{ about: h.about.replace("{label}", labels[key].label),
            text: fillHint(labels[key].hint, { hours: h.officeHours, target: targetMinutes, warning: warningPct }, locale), more: moreOf?.(key) }} />
      ))}
    </StatPanel>
  );
}
