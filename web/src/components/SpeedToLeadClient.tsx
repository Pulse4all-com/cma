"use client";

/**
 * The client parts of Sales → Speed to lead's cockpit (addition 0009zr, brief B40b): the market buttons (K focuses the
 * chosen one; a click loads the whole page for that market, the choice shown at once while it loads), the deals list's
 * rows with their attempts opened and closed in place (Show attempts), and the refresh every 60 seconds while the period
 * reaches today, through the page's own route (router.refresh, no poll route), paused while the tab is hidden. Each part
 * takes only the words it shows, never the whole catalog.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { Fragment, useEffect, useState } from "react";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { Keycap } from "./primitives";
import { RecordLink } from "./RecordLink";
import { PENDING_ROW, usePendingChoice } from "./usePendingPush";

export const SPEED_REFRESH_MS = 60_000;

/** The page read again every 60 seconds while visible, and once when the tab comes back (as LiveRefresh, at a minute) */
export function SpeedRefresh() {
  const router = useRouter();
  useEffect(() => {
    let id: ReturnType<typeof setTimeout> | null = null;
    const tick = () => {
      router.refresh();
      id = setTimeout(tick, SPEED_REFRESH_MS);
    };
    const start = () => {
      if (id === null) id = setTimeout(tick, SPEED_REFRESH_MS);
    };
    const stop = () => {
      if (id !== null) clearTimeout(id);
      id = null;
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        router.refresh();
        start();
      } else {
        stop();
      }
    };
    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [router]);
  return null;
}

/** All markets, then each market with deals in the period, as toggle buttons; K focuses the chosen one */
export function MarketButtons({ markets, market, hrefs, words }: {
  /** Market codes with deals in the period ("unknown" for deals without a catalog market) */
  markets: string[];
  /** The chosen market, "" for all */
  market: string;
  /** The page's address per choice ("" for all markets), built on the server with the period and the rest kept */
  hrefs: Record<string, string>;
  words: { label: string; all: string; unknown: string };
}) {
  const [pending, shown, choose] = usePendingChoice(market);
  const options = ["", ...markets];
  return (
    <div role="group" aria-label={words.label} className={`flex flex-wrap items-center gap-2 ${PENDING_ROW}`} aria-busy={pending || undefined}
      data-testid="speed-market">
      <span className="mr-1 flex items-center gap-2 text-small font-semibold">
        {words.label} <Keycap>K</Keycap>
      </span>
      {options.map((m) => {
        const on = m === shown;
        return (
          <button key={m || "all"} type="button" aria-pressed={on} data-shortcut={on ? "k" : undefined} data-market={m || "all"}
            onClick={() => { if (m !== shown) choose(m, hrefs[m] as Route, { scroll: false }); }}
            className={["inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              on ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border bg-white text-p4a-deepblue hover:bg-p4a-bgblue"].join(" ")}>
            {m === "" ? words.all : m === "unknown" ? words.unknown : m}
          </button>
        );
      })}
    </div>
  );
}

/** One attempt as the row's detail shows it, every text already in words and the times formatted */
export interface AttemptLine {
  n: string; start: string; after: string; connected: string; talk: string; conversation: string; tag: string; agent: string;
}

/** A deal of the list as the client draws it: the cells already formatted on the server */
export interface DealLine {
  id: string;
  sourceId: string;
  recordUrl: string | null;
  recordLabel: string;
  market: string;
  owner: string;
  ownerMuted: boolean;
  created: string;
  attempts: string;
  speed: string;
  speedTone: "good" | "bad" | "muted";
  stale: string | null;
  timeline: {
    label: string; target: number | null; cutoff: number | null; waiting: number | null; beyond: boolean;
    dots: { n: number; at: number; kind: "notConnected" | "connected" | "conversation"; title: string }[];
  } | null;
  lines: AttemptLine[];
  firstOf: string | null;
}

export interface DealHeader { label: string; about: string; hint: string; className?: string }

const DOT: Record<"notConnected" | "connected" | "conversation", string> = {
  notConnected: "border-2 border-p4a-denim bg-white",
  connected: "border-2 border-p4a-denim bg-p4a-denim",
  conversation: "border-2 border-p4a-green bg-p4a-green",
};

/** The deals list's table: one row per deal, its attempts opened under it (Show attempts / Hide attempts) */
export function SpeedDealRows({ rows, headers, attemptHeaders, words }: {
  rows: DealLine[];
  headers: DealHeader[];
  attemptHeaders: DealHeader[];
  words: { show: string; hide: string; noPersonalData: string; actions: string; beyond: string };
}) {
  const [open, setOpen] = useState<string | null>(null);
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "px-3 py-2 align-middle";
  return (
    <table className="w-full border-collapse text-body" data-testid="speed-deals">
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {headers.map((h) => (
            <th key={h.label} className={`${th} ${h.className ?? ""}`}>
              <HintLabel label={h.label}><HeaderHint label={h.about} text={h.hint} /></HintLabel>
            </th>
          ))}
          <th className={`${th} w-12`}><span className="sr-only">{words.actions}</span></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((d) => {
          const isOpen = open === d.id;
          return (
            <Fragment key={d.id}>
              <tr className={`border-b border-p4a-border ${d.stale ? "bg-p4a-neutral-surface text-p4a-muted" : ""}`} data-testid="speed-deal" data-stale={d.stale ? "true" : undefined}>
                <td className={`${td} tabular whitespace-nowrap font-semibold`}>{d.sourceId}</td>
                <td className={td}>{d.market}</td>
                <td className={`${td} ${d.ownerMuted ? "text-p4a-muted" : ""}`}>{d.owner}</td>
                <td className={`${td} tabular whitespace-nowrap`}>{d.created}</td>
                <td className={`${td} tabular text-right text-title font-bold text-p4a-heading`}>{d.attempts}</td>
                <td className={`${td} tabular whitespace-nowrap text-right font-semibold ${d.speedTone === "good" ? "text-p4a-green" : d.speedTone === "bad" ? "text-p4a-error" : "text-p4a-muted"}`}>
                  {d.speed}
                </td>
                <td className={`${td} min-w-48`}>
                  {d.timeline ? (
                    <div className="relative h-6" role="img" aria-label={d.timeline.label} data-testid="speed-timeline">
                      <span aria-hidden="true" className="absolute left-0 right-0 top-[11px] h-0.5 bg-p4a-border" />
                      {d.timeline.waiting !== null ? (
                        <span aria-hidden="true" className="absolute left-0 top-[7px] h-2.5 rounded-r bg-p4a-error-surface" style={{ width: `${d.timeline.waiting}%` }} />
                      ) : null}
                      {d.timeline.target !== null ? (
                        <span aria-hidden="true" className="absolute top-1 h-4 w-0.5 bg-p4a-grey" style={{ left: `${d.timeline.target}%` }} data-mark="target" />
                      ) : null}
                      {d.timeline.cutoff !== null ? (
                        <span aria-hidden="true" className="absolute top-0.5 h-5 w-0.5 bg-p4a-inkt" style={{ left: `${d.timeline.cutoff}%` }} data-mark="cutoff" />
                      ) : null}
                      {d.timeline.dots.map((x) => (
                        <span key={x.n} title={x.title} className={`absolute top-1.5 h-3 w-3 -translate-x-1.5 rounded-full ${DOT[x.kind]}`} style={{ left: `${x.at}%` }}
                          data-dot={x.kind} />
                      ))}
                      {d.timeline.beyond ? (
                        <span title={words.beyond} className="absolute -right-3 top-0 text-body font-bold text-p4a-grey" data-beyond="">›</span>
                      ) : null}
                    </div>
                  ) : <span className="text-p4a-muted">–</span>}
                  {d.stale ? <p className="mt-1 text-caption">{d.stale}</p> : null}
                </td>
                <td className={`${td} whitespace-nowrap text-right`}>
                  <span className="inline-flex items-center gap-1">
                    {d.lines.length > 0 ? (
                      <button type="button" aria-expanded={isOpen} aria-controls={`attempts-${d.id}`} onClick={() => setOpen(isOpen ? null : d.id)}
                        className="inline-flex h-8 items-center rounded-button border border-p4a-border px-3 text-small font-semibold text-p4a-deepblue hover:bg-p4a-bgblue">
                        {isOpen ? words.hide : words.show}
                      </button>
                    ) : null}
                    <RecordLink url={d.recordUrl} label={d.recordLabel} />
                  </span>
                </td>
              </tr>
              {isOpen ? (
                <tr id={`attempts-${d.id}`} className="border-b border-p4a-border bg-p4a-offwhite" data-testid="speed-attempts">
                  <td colSpan={headers.length + 1} className="px-3 py-3">
                    <table className="w-full border-collapse text-small">
                      <thead>
                        <tr className="text-left text-p4a-heading">
                          {attemptHeaders.map((h) => (
                            <th key={h.label} className={`h-8 px-2 font-semibold ${h.className ?? ""}`}>
                              <HintLabel label={h.label}><HeaderHint label={h.about} text={h.hint} /></HintLabel>
                            </th>
                          ))}
                        </tr>
                      </thead>
                      <tbody>
                        {d.lines.map((a) => (
                          <tr key={a.n} className="border-t border-p4a-border">
                            <td className="tabular px-2 py-1">{a.n}</td>
                            <td className="tabular whitespace-nowrap px-2 py-1">{a.start}</td>
                            <td className="tabular whitespace-nowrap px-2 py-1">{a.after}</td>
                            <td className="px-2 py-1">{a.connected}</td>
                            <td className="tabular px-2 py-1">{a.talk}</td>
                            <td className="px-2 py-1">{a.conversation}</td>
                            <td className="px-2 py-1">{a.tag}</td>
                            <td className="px-2 py-1">{a.agent}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                    {d.firstOf ? <p className="mt-2 text-caption text-p4a-grey">{d.firstOf}</p> : null}
                    <p className="mt-2 text-caption text-p4a-grey">{words.noPersonalData}</p>
                  </td>
                </tr>
              ) : null}
            </Fragment>
          );
        })}
      </tbody>
    </table>
  );
}
