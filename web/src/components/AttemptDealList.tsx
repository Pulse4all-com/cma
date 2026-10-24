"use client";

/**
 * The deals of Reports → Attempts per deal (addition 0008z, 20 October 2026): open deals first, the longest since their
 * last attempt first, then the deals won, lost or ordered another way, the latest first (capped by follow_up.list_rows).
 * A deal's row opens with Enter on its id or a click anywhere on it and shows the deal's attempts in time order, read
 * once from /api/v1/reports/attempts/deals/{dealId}; Esc closes it and puts the focus back on the deal, Up and Down move
 * between the deals. The attempts show their number, start, connected, talk time, conversation (addition 0008zc) and the call's
 * outcome; the agent column only when the database names agents (the per-person figures for attempts on and the reader
 * holding performance.team). Rows follow Pulse4all-Style 7.6 (zebra rows, a hover row, at least 40px), the table scrolls
 * sideways inside its card. Ids, codes, counts, links and times only: never a call id, number or recording.
 */
import { Fragment, useRef, useState, type KeyboardEvent } from "react";
import type { Locale } from "@/lib/copy";
import type { AttemptListRow, DealAttempt } from "@/lib/data";
import { speedMinutes, type AttemptClientCopy } from "@/lib/attempts";
import { fmtBusinessMinutes, fmtCount, fmtTalk } from "@/lib/reports";
import { dateKeyInZone, fmtDate, fmtDateTimeShort } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";

type Loaded = { state: "loading" } | { state: "failed" } | { state: "done"; attempts: DealAttempt[] };

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const cell = "h-10 whitespace-nowrap px-2";

export function AttemptDealList({ rows, hints, copy, locale, timeZone }: {
  rows: AttemptListRow[];
  /** The attempts hints with the tenant's values filled in */
  hints: Record<string, string>;
  copy: AttemptClientCopy;
  locale: Locale;
  timeZone: string;
}) {
  const t = copy.attempts;
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const [loaded, setLoaded] = useState<Record<string, Loaded>>({});
  const buttons = useRef<Map<string, HTMLButtonElement>>(new Map());
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string | undefined) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text ?? ""} />;
  const time = (at: string | null) => (at ? fmtDateTimeShort(at, timeZone, locale) : "–");
  const keys = rows.map((r) => r.dealId);

  function load(dealId: string) {
    setLoaded((prev) => ({ ...prev, [dealId]: { state: "loading" } }));
    fetch(`/api/v1/reports/attempts/deals/${dealId}`, { cache: "no-store" })
      .then(async (res) => {
        if (!res.ok) throw new Error(String(res.status));
        const attempts = ((await res.json()) as { data: DealAttempt[] }).data;
        setLoaded((prev) => ({ ...prev, [dealId]: { state: "done", attempts } }));
      })
      .catch(() => setLoaded((prev) => ({ ...prev, [dealId]: { state: "failed" } })));
  }

  function toggle(dealId: string) {
    const opening = !open.has(dealId);
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(dealId)) next.delete(dealId);
      else next.add(dealId);
      return next;
    });
    // read once; a failed read is tried again on the next open
    if (opening && (!loaded[dealId] || loaded[dealId].state === "failed")) load(dealId);
  }

  function close(dealId: string) {
    if (!open.has(dealId)) return;
    setOpen((prev) => {
      const next = new Set(prev);
      next.delete(dealId);
      return next;
    });
    buttons.current.get(dealId)?.focus();
  }

  function onKey(e: KeyboardEvent<HTMLElement>, dealId: string) {
    if (e.key === "Escape" && open.has(dealId)) {
      e.preventDefault();
      e.stopPropagation();
      close(dealId);
      return;
    }
    if (e.currentTarget.tagName !== "BUTTON" || (e.key !== "ArrowDown" && e.key !== "ArrowUp")) return;
    e.preventDefault();
    const next = keys[keys.indexOf(dealId) + (e.key === "ArrowDown" ? 1 : -1)];
    if (next) buttons.current.get(next)?.focus();
  }

  const columns = 14;

  return (
    <div className="relative overflow-x-auto" data-testid="attempts-list-scroll" role="region" aria-label={t.listTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="attempts-list">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.deal}>{hint(t.deal, hints.atDeal)}</HintLabel></th>
            <th className={th}><HintLabel label={t.pipeline}>{hint(t.pipeline, hints.atPipeline)}</HintLabel></th>
            <th className={th}><HintLabel label={t.stage}>{hint(t.stage, hints.atStage)}</HintLabel></th>
            <th className={th}><HintLabel label={t.market}>{hint(t.market, hints.atMarket)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.created}>{hint(t.created, hints.atCreated)}</HintLabel></th>
            <th className={th}><HintLabel label={t.outcome}>{hint(t.outcome, hints.atOutcome)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.attemptsCol}>{hint(t.attemptsCol, hints.atAttempts)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.conversationCol}>{hint(t.conversationCol, hints.atConversationCol)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.firstConversation}>{hint(t.firstConversation, hints.atFirstConversation)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.talkConversation}>{hint(t.talkConversation, hints.atTalkConversation)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.speedCol}>{hint(t.speedCol, hints.atSpeedCol)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.lastAttempt}>{hint(t.lastAttempt, hints.atLastAttempt)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.daysSince}>{hint(t.daysSince, hints.atDaysSince)}</HintLabel></th>
            <th className={th}><span className="sr-only">{t.open}</span>{hint(t.open, hints.atOpenLink)}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const expanded = open.has(r.dealId);
            const outcome = t[`outcome_${r.outcome}`];
            const orderedTitle = r.outcome === "ordered" && r.orderedAt ? t.orderedOn.replace("{date}", fmtDate(dateKeyInZone(new Date(r.orderedAt), timeZone), locale)) : undefined;
            return (
              <Fragment key={r.dealId}>
                <tr className="cursor-pointer border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50"
                  data-testid="attempts-row" data-outcome={r.outcome} data-deal={r.dealId} data-attempts={r.attempts}
                  onClick={(e) => {
                    // a click on the row opens it; the record link keeps its own click
                    if ((e.target as HTMLElement).closest("a")) return;
                    toggle(r.dealId);
                  }}>
                  <td className={`${cell} font-semibold tabular`}>
                    <button
                      type="button"
                      ref={(el) => { if (el) buttons.current.set(r.dealId, el); else buttons.current.delete(r.dealId); }}
                      aria-expanded={expanded}
                      aria-controls={`deal-attempts-${r.dealId}`}
                      aria-label={(expanded ? t.collapse : t.expand).replace("{deal}", r.dealSourceId)}
                      onClick={(e) => { e.stopPropagation(); toggle(r.dealId); }}
                      onKeyDown={(e) => onKey(e, r.dealId)}
                      className="inline-flex items-center gap-2 rounded-button text-left font-semibold text-p4a-body hover:text-p4a-deepblue"
                      data-testid="attempts-toggle"
                    >
                      <svg aria-hidden="true" viewBox="0 0 16 16" className={`h-3 w-3 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M6 3l5 5-5 5" />
                      </svg>
                      <span>{r.dealSourceId}</span>
                    </button>
                  </td>
                  <td className={`${cell} max-w-[12rem] overflow-hidden text-ellipsis`} title={r.pipelineLabel ?? undefined}>{r.pipelineLabel ?? "–"}</td>
                  <td className={`${cell} max-w-[10rem] overflow-hidden text-ellipsis`} title={r.stageLabel ?? undefined}>{r.stageLabel ?? "–"}</td>
                  <td className={cell}>{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
                  <td className={td}>{time(r.createdAt)}</td>
                  <td className={cell} title={orderedTitle}>{outcome}</td>
                  <td className={td}>{n(r.attempts)}</td>
                  <td className={td}>{n(r.conversationAttempts)}</td>
                  <td className={td}>{r.firstConversationAttempt === null ? "–" : n(r.firstConversationAttempt)}</td>
                  <td className={td}>{r.conversationAttempts === 0 ? "–" : fmtTalk(r.talkSecondsConversation, locale)}</td>
                  <td className={td}>{fmtBusinessMinutes(speedMinutes(r.speedToLeadSeconds), locale)}</td>
                  <td className={td}>{time(r.lastAttemptAt)}</td>
                  <td className={td}>{r.outcome !== "open" ? "" : r.businessDaysSinceLast === null ? "–" : n(r.businessDaysSinceLast)}</td>
                  <td className="h-10 px-2 text-right"><RecordLink url={r.recordUrl} label={`${t.open} ${r.dealSourceId}`} /></td>
                </tr>
                {expanded ? (
                  <tr id={`deal-attempts-${r.dealId}`} className="border-b border-p4a-border bg-white" data-testid="attempts-detail"
                    onKeyDown={(e) => onKey(e, r.dealId)}>
                    <td colSpan={columns} className="px-2 py-3">
                      <DealAttempts dealSourceId={r.dealSourceId} loaded={loaded[r.dealId] ?? { state: "loading" }} hints={hints} copy={copy} locale={locale} time={time} />
                    </td>
                  </tr>
                ) : null}
              </Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/** One deal's attempts in time order, or the loading or failed line */
function DealAttempts({ dealSourceId, loaded, hints, copy, locale, time }: {
  dealSourceId: string; loaded: Loaded; hints: Record<string, string>; copy: AttemptClientCopy; locale: Locale; time: (at: string | null) => string;
}) {
  const t = copy.attempts;
  const title = t.attemptsOf.replace("{deal}", dealSourceId);
  if (loaded.state === "loading") return <p className="text-small text-p4a-muted" role="status" data-testid="attempts-detail-loading">{t.attemptsLoading}</p>;
  if (loaded.state === "failed") return <p className="text-small text-p4a-body" role="alert" data-testid="attempts-detail-failed">{t.attemptsFailed}</p>;
  if (loaded.attempts.length === 0) return <p className="text-small text-p4a-muted" data-testid="attempts-detail-none">{t.attemptsNone}</p>;
  const hint = (label: string, text: string | undefined) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text ?? ""} />;
  const agents = loaded.attempts.some((a) => a.agentName !== null);
  const sub = "h-9 px-2 py-1 align-bottom font-semibold";
  return (
    <table className="border-collapse text-small leading-table" data-testid="attempts-detail-table" aria-label={title}>
      <thead>
        <tr className="border-b border-p4a-border text-left text-p4a-heading">
          <th className={`${sub} text-right`}><HintLabel label={t.colN}>{hint(t.colN, hints.atAN)}</HintLabel></th>
          <th className={`${sub} text-right`}><HintLabel label={t.colStart}>{hint(t.colStart, hints.atAStart)}</HintLabel></th>
          <th className={sub}><HintLabel label={t.colConnected}>{hint(t.colConnected, hints.atAConnected)}</HintLabel></th>
          <th className={`${sub} text-right`}><HintLabel label={t.colTalkTime}>{hint(t.colTalkTime, hints.atATalk)}</HintLabel></th>
          <th className={sub}><HintLabel label={t.colIsConversation}>{hint(t.colIsConversation, hints.atAConversation)}</HintLabel></th>
          <th className={sub}><HintLabel label={t.colCallOutcome}>{hint(t.colCallOutcome, hints.atAOutcome)}</HintLabel></th>
          {agents ? <th className={sub}><HintLabel label={t.colAgent}>{hint(t.colAgent, hints.atAAgent)}</HintLabel></th> : null}
        </tr>
      </thead>
      <tbody>
        {loaded.attempts.map((a) => (
          <tr key={a.n} className="border-b border-p4a-border last:border-b-0" data-testid="attempt-row" data-conversation={a.conversation ? "yes" : "no"}>
            <td className="h-9 px-2 tabular text-right">{fmtCount(a.n, locale)}</td>
            <td className="h-9 whitespace-nowrap px-2 tabular text-right">{time(a.startedAt)}</td>
            <td className="h-9 px-2">{a.connected ? t.yes : t.no}</td>
            <td className="h-9 px-2 tabular text-right">{a.talkSeconds === null ? "–" : fmtTalk(a.talkSeconds, locale)}</td>
            <td className="h-9 whitespace-nowrap px-2">{a.conversation ? t.yes : t.no}</td>
            <td className="h-9 max-w-[16rem] overflow-hidden text-ellipsis whitespace-nowrap px-2" title={a.outcomeLabel ?? undefined}>{a.outcomeLabel ?? t.noOutcome}</td>
            {agents ? <td className="h-9 whitespace-nowrap px-2">{a.agentName ?? "–"}</td> : null}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
