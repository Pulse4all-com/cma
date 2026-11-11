"use client";

/**
 * The Live board's poll (addition 0008zr's web, night N06; the IT audit's 5.6-01): the board, the inbound tiles, the
 * outbound tiles (addition 0009h), the follow-up strip and the missed callers from one read, GET /api/v1/live/board, fetched every 10 seconds while the tab
 * is visible and once more when it comes back, never while it is hidden; after a failed poll the wait doubles up to a
 * minute. The answer replaces the data and the rows are computed again (lib/live-board, the same function the page
 * used for the first render), so a poll costs one transaction instead of the page's render (eight transactions and 26
 * statements before). The filters the board holds survive every poll: they are the board's own state. Since addition
 * 0008zv the board is one contact center's: the poll asks for its organisation (?organisation=<key>), and the inbound,
 * outbound and missed-call parts, which stay tenant-wide, say they cover all lines, and the follow-up strip the whole business line.
 *
 * The Live board's UX pass (10 November 2026): the board says when it read last ("Updated 14:32:05") and, after two failed
 * polls in a row, that its figures are old and it keeps trying, calmly (docs/style/Pulse4all-Style.md 2.3 and 5), so
 * nobody acts on figures that stopped; a poll gives up after LIVE_POLL_TIMEOUT_MS. The parts are panels with a 24px gap,
 * so every figure fits on the first screen; Inbound today by hour (LiveHours, for a holder of reports.view or
 * performance.team) sits between the team and the missed callers, which stay last.
 */
import { useCallback, useEffect, useState } from "react";
import { FollowUpLive } from "./FollowUpLive";
import { InboundLive, MissedCallbacks } from "./InboundLive";
import { LiveBoard } from "./LiveBoard";
import { OutboundLive } from "./OutboundLive";
import { LiveHours } from "./LiveHours";
import { Badge, Card, PageTitle } from "./primitives";
import type { ContactCenter } from "@/lib/auth/identity";
import type { LiveBoardData } from "@/lib/data";
import { type FollowUpTileKey } from "@/lib/follow-up";
import { employersOf, isStale, LIVE_POLL_TIMEOUT_MS, teamsOf, tiles, type LiveBoardWords } from "@/lib/live";
import { boardRowsOf, nextPollMs, type LiveViewer } from "@/lib/live-board";
import { timeInZone } from "@/lib/reports";
import { metricsHref } from "@/lib/metrics";

/** The Follow-up now strip's entries in the metric catalog, per tile */
const STRIP_METRIC: Record<FollowUpTileKey, string> = {
  leadsOpenNotCalled: "leads_open_not_called",
  leadsPastTarget: "leads_past_target",
  ticketsAtRisk: "tickets_at_risk",
  ticketsBreached: "tickets_breached",
  tasksOverdue: "tasks_overdue",
  tasksDueToday: "tasks_due_today",
};

export type LiveBoardCopy = LiveBoardWords;

export function LiveBoardLive({ initial, organisation, viewer, copy, canOpenMetrics, canReadHours = false, heading }: {
  initial: LiveBoardData;
  /** The contact center whose board this is (addition 0008zv): its people only, polled with its key */
  organisation: ContactCenter;
  viewer: LiveViewer;
  copy: LiveBoardCopy;
  /** True for a holder of tenant.configure: each tile's hint links to its entry on Configuration → Metrics */
  canOpenMetrics: boolean;
  /** True for a holder of reports.view or performance.team: Inbound today by hour, from Reports → Inbound's read */
  canReadHours?: boolean;
  /** Today's date for the title row: the board draws its title row and intro, so its freshness sits on the title's line */
  heading: { date: string };
}) {
  const [data, setData] = useState(initial);
  // Failed polls in a row, for the board's word on its own freshness (the loop keeps its own count for the wait)
  const [failed, setFailed] = useState(0);
  const t = copy.live;
  const organisationKey = organisation.key;
  // The call parts count every line of the tenant, not only this contact center's (addition 0008zv)
  const allLines = t.callsAllLines.replace("{organisation}", organisation.name);
  // and the follow-up counts the whole business line's leads, tickets and tasks (Martin, 5 November 2026)
  const wholeBusinessLine = t.followUpWholeBusinessLine.replace("{organisation}", organisation.name);

  const poll = useCallback(async (): Promise<boolean> => {
    try {
      const res = await fetch(`/api/v1/live/board?organisation=${encodeURIComponent(organisationKey)}`,
        { cache: "no-store", signal: AbortSignal.timeout(LIVE_POLL_TIMEOUT_MS) });
      if (!res.ok) return false;
      const body = (await res.json()) as { data: LiveBoardData };
      setData(body.data);
      return true;
    } catch {
      return false;
    }
  }, [organisationKey]);

  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    let stopped = false;
    let failures = 0;
    // One loop at a time: a poll still in flight when the tab is hidden and shown again must not schedule a second
    // loop next to the one the visibility change starts, so each loop carries its generation and a stale one stops
    let generation = 0;
    const tick = async (gen: number) => {
      if (document.hidden || gen !== generation) { if (gen === generation) timer = null; return; }
      const ok = await poll();
      if (gen !== generation) return;
      failures = ok ? 0 : failures + 1;
      setFailed(failures);
      if (stopped || document.hidden) { timer = null; return; }
      timer = setTimeout(() => void tick(gen), nextPollMs(failures));
    };
    const onVisibility = () => {
      if (timer) clearTimeout(timer);
      timer = null;
      generation += 1;
      if (document.visibilityState === "visible") void tick(generation);
    };
    if (document.visibilityState === "visible") { const gen = generation; timer = setTimeout(() => void tick(gen), nextPollMs(0)); }
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [poll]);

  const { rows, board } = boardRowsOf(data, viewer);
  const moreOf = canOpenMetrics
    ? (key: FollowUpTileKey) => ({ href: metricsHref(`live.follow_up_now.${STRIP_METRIC[key]}`), label: copy.hints.howComputed })
    : undefined;

  const readAt = timeInZone(data.readAt, viewer.timeZone);
  const stale = isStale(failed);

  return (
    <div data-live-board-read-at={data.readAt}>
      <PageTitle aside={
        <p className="flex shrink-0 items-center gap-2 text-caption font-normal text-p4a-grey" data-testid="live-freshness">
          {stale ? (
            <span role="status" className="flex items-center gap-2" data-testid="live-stale">
              <Badge tone="warning">{t.notUpdatedSince.replace("{time}", readAt)}</Badge>
              <span className="text-p4a-muted">{t.tryingAgain}</span>
            </span>
          ) : (
            <span><span className="tabular">{t.updatedAt.replace("{time}", readAt)}</span> · {t.refreshHint}</span>
          )}
        </p>
      }>
        {t.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{heading.date}</span>
      </PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <div className="mb-6">
        <InboundLive inbound={data.inbound} copy={copy} locale={viewer.locale} canOpenMetrics={canOpenMetrics} scope={allLines} />
      </div>

      {data.outbound ? (
        <div className="mb-6">
          <OutboundLive outbound={data.outbound} copy={copy} locale={viewer.locale} canOpenMetrics={canOpenMetrics} scope={allLines}
            connectedMinSeconds={data.settings.connectedMinSeconds} conversationMinSeconds={data.settings.conversationMinSeconds} />
        </div>
      ) : null}

      <div className="mb-6">
        <FollowUpLive summary={data.followUp} copy={copy} locale={viewer.locale}
          targetMinutes={data.settings.targetMinutes} warningPct={data.settings.warningPct} moreOf={moreOf} scope={wholeBusinessLine} />
      </div>

      {rows.length === 0 ? (
        <Card>
          <h2 className="mb-2 text-panel font-semibold text-p4a-heading">{t.teamTitle}</h2>
          <p className="text-body text-p4a-muted">{t.noPeople}</p>
        </Card>
      ) : (
        <LiveBoard
          rows={board}
          tiles={tiles(rows, data.now.statusFlags)}
          employers={employersOf(rows)}
          teams={teamsOf(rows, data.memberships)}
          copy={copy}
          locale={viewer.locale}
        />
      )}

      {/* its own top margin, so a chart that hides itself (no permission after all, no telephony) leaves no gap */}
      {canReadHours && data.inbound.telephony && data.inbound.today ? (
        <LiveHours date={data.inbound.today.date} copy={copy} locale={viewer.locale} timeZone={viewer.timeZone} scope={allLines} />
      ) : null}

      <div className="mt-6">
        <MissedCallbacks inbound={data.inbound} copy={copy} locale={viewer.locale} timeZone={viewer.timeZone} scope={allLines} />
      </div>
    </div>
  );
}
