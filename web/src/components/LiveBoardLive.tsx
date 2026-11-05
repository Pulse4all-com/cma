"use client";

/**
 * The Live board's poll (addition 0008zr's web, night N06; the IT audit's 5.6-01): the board, the inbound tiles, the
 * follow-up strip and the missed callers from one read, GET /api/v1/live/board, fetched every 10 seconds while the tab
 * is visible and once more when it comes back, never while it is hidden; after a failed poll the wait doubles up to a
 * minute. The answer replaces the data and the rows are computed again (lib/live-board, the same function the page
 * used for the first render), so a poll costs one transaction instead of the page's render (eight transactions and 26
 * statements before). The filters the board holds survive every poll: they are the board's own state. Since addition
 * 0008zv the board is one contact center's: the poll asks for its organisation (?organisation=<key>), and the inbound
 * and missed-call parts, which stay tenant-wide, say they cover all lines, and the follow-up strip the whole business line.
 */
import { useCallback, useEffect, useState } from "react";
import { FollowUpLive } from "./FollowUpLive";
import { InboundLive, MissedCallbacks, type InboundCopy } from "./InboundLive";
import { LiveBoard } from "./LiveBoard";
import { Card } from "./primitives";
import type { ContactCenter } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import type { LiveBoardData } from "@/lib/data";
import { type FollowUpTileKey } from "@/lib/follow-up";
import { employersOf, teamsOf, tiles } from "@/lib/live";
import { boardRowsOf, nextPollMs, type LiveViewer } from "@/lib/live-board";
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

export type LiveBoardCopy = InboundCopy & Pick<Copy, "followUp" | "dashboard">;

export function LiveBoardLive({ initial, organisation, viewer, copy, canOpenMetrics }: {
  initial: LiveBoardData;
  /** The contact center whose board this is (addition 0008zv): its people only, polled with its key */
  organisation: ContactCenter;
  viewer: LiveViewer;
  copy: LiveBoardCopy;
  /** True for a holder of tenant.configure: each tile's hint links to its entry on Configuration → Metrics */
  canOpenMetrics: boolean;
}) {
  const [data, setData] = useState(initial);
  const t = copy.live;
  const organisationKey = organisation.key;
  // The call parts count every line of the tenant, not only this contact center's (addition 0008zv)
  const allLines = t.callsAllLines.replace("{organisation}", organisation.name);
  // and the follow-up counts the whole business line's leads, tickets and tasks (Martin, 5 November 2026)
  const wholeBusinessLine = t.followUpWholeBusinessLine.replace("{organisation}", organisation.name);

  const poll = useCallback(async (): Promise<boolean> => {
    try {
      const res = await fetch(`/api/v1/live/board?organisation=${encodeURIComponent(organisationKey)}`, { cache: "no-store" });
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

  return (
    <div data-live-board-read-at={data.readAt}>
      <div className="mb-8">
        <InboundLive inbound={data.inbound} copy={copy} locale={viewer.locale} canOpenMetrics={canOpenMetrics} scope={allLines} />
      </div>

      <div className="mb-8">
        <FollowUpLive summary={data.followUp} copy={copy} locale={viewer.locale}
          targetMinutes={data.settings.targetMinutes} warningPct={data.settings.warningPct} moreOf={moreOf} scope={wholeBusinessLine} />
      </div>

      <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.teamTitle}</h2>
      {rows.length === 0 ? (
        <Card>
          <p className="text-body text-p4a-muted">{t.noPeople}</p>
        </Card>
      ) : (
        <LiveBoard
          rows={board}
          tiles={tiles(rows, data.now.statusFlags)}
          employers={employersOf(rows)}
          teams={teamsOf(rows, data.memberships)}
          copy={copy}
        />
      )}

      <div className="mt-8">
        <MissedCallbacks inbound={data.inbound} copy={copy} locale={viewer.locale} timeZone={viewer.timeZone} scope={allLines} />
      </div>
    </div>
  );
}
