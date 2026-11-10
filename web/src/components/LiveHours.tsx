"use client";

/**
 * Inbound today by hour on the Live board (the Live board's UX pass, 10 November 2026; Martin: "include some nice
 * charts"): a column per hour, 00 to 23, of today's answered and unanswered inbound calls, from Reports → Inbound's own
 * read (GET /api/v1/reports/inbound?group=hour for today: each call's hour in its line's zone, the report's figures), so
 * the board adds no read to its 10-second poll: this one is fetched after the first paint and a minute after each read
 * while the tab is visible (one at a time; a tab that comes back within the minute waits for the rest of it, hoursDue).
 * For a holder of reports.view or performance.team (the report's permission); the board passes it only then.
 *
 * Built by the dataviz rules and docs/style/Pulse4all-Style.md 7.7, in plain HTML and CSS as the Dashboard's charts: one
 * axis (counts), columns at most 24px wide with a 4px rounded data end and a 2px surface gap between the stacked parts,
 * hairline solid gridlines, axis labels 12px Footnote Grey. Answered is Deep Blue (7.7's first series) and unanswered
 * Warning amber (2.3: "needs attention"): 7.7's next colours do not fit, Leaf Green reads as positive and Light Blue and
 * Soft Rose fail the palette validator's chroma and normal-vision checks; Deep Blue and amber pass its lightness, chroma,
 * colour-blind and normal-vision checks on white, and amber's contrast warning is met by the legend, the tooltip and the
 * table view. Waiting calls (only ever in the running hour) are in the tooltip, not a third colour. The columns are one
 * Tab stop (the arrow keys move between the hours, Home and End to the first and last) with the global focus ring, and
 * show the same figures on focus as on hover; the values are also in a table for screen readers and on Reports →
 * Inbound. The running hour (in the viewer's zone; the columns are each line's hours) is marked under the axis. While
 * the first read is under way the plot keeps its size, so nothing jumps; a read that fails says so calmly (none yet, or
 * since when the chart has not been read) and the next minute tries again.
 */
import Link from "next/link";
import { useEffect, useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { InboundService } from "@/lib/data";
import { hoursDue, inboundHours, LIVE_HOURS_MS, LIVE_POLL_TIMEOUT_MS, niceCeiling, type InboundHour, type LiveHints } from "@/lib/live";
import { fmtCount, fmtPct, timeInZone } from "@/lib/reports";
import { hourInZone } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";

const PLOT_PX = 128;
const pad = (h: number) => String(h).padStart(2, "0");

export function LiveHours({ date, copy, locale, timeZone, scope }: {
  /** Today's date in the tenant's zone, as Inbound today's */
  date: string;
  copy: Pick<Copy, "live" | "inbound"> & { hints: LiveHints };
  locale: Locale;
  /** The viewer's zone, for the running hour's mark */
  timeZone: string;
  /** A caption after the title on what the chart covers (a contact center's board: all lines) */
  scope?: string;
}) {
  const t = copy.live;
  const [hours, setHours] = useState<InboundHour[] | null>(null);
  const [hidden, setHidden] = useState(false);
  const [active, setActive] = useState<number | null>(null);
  const [nowHour, setNowHour] = useState<number | null>(null);
  // The roving Tab stop: the column that takes the focus (the arrow keys move it)
  const [focusHour, setFocusHour] = useState<number | null>(null);
  // When the chart was read last, and whether the latest read failed (the board's line covers the poll, not this read)
  const [readAt, setReadAt] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    // one read at a time, and the instant of the last one: the timer runs from it, and a tab that comes back within the
    // minute waits for the rest of it (hoursDue)
    let inFlight = false;
    let lastAt = 0;
    const load = async () => {
      if (inFlight) return;
      inFlight = true;
      try {
        const res = await fetch(`/api/v1/reports/inbound?from=${date}&to=${date}&group=hour`,
          { cache: "no-store", signal: AbortSignal.timeout(LIVE_POLL_TIMEOUT_MS) });
        // not the report's permission after all, or no telephony: the board shows no chart rather than an empty one
        if (res.status === 403) { if (!stopped) setHidden(true); return; }
        if (!res.ok) { if (!stopped) setFailed(true); return; }
        const body = (await res.json()) as { data: InboundService };
        if (stopped) return;
        if (!body.data.telephony) { setHidden(true); return; }
        setHours(inboundHours(body.data.rows));
        setNowHour(hourInZone(new Date(), timeZone));
        setReadAt(new Date().toISOString());
        setFailed(false);
      } catch {
        // a failed read (or one past the timeout) keeps the last chart and says since when it is old
        if (!stopped) setFailed(true);
      } finally {
        inFlight = false;
        lastAt = Date.now();
      }
    };
    // the next read a minute after the last one, armed only while the tab is visible
    const arm = () => {
      if (timer) clearTimeout(timer);
      timer = null;
      if (stopped || document.hidden) return;
      timer = setTimeout(() => { void load().then(arm); }, Math.max(0, LIVE_HOURS_MS - (Date.now() - lastAt)));
    };
    void load().then(arm);
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        if (hoursDue(lastAt, Date.now())) void load().then(arm);
        else arm();
      } else if (timer) {
        clearTimeout(timer);
        timer = null;
      }
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [date, timeZone]);

  if (hidden) return null;
  const top = niceCeiling(Math.max(0, ...(hours ?? []).map((h) => h.answered + h.unanswered)));
  const any = (hours ?? []).some((h) => h.offered > 0);
  const range = (h: number) => t.hoursRange.replace("{from}", `${pad(h)}:00`).replace("{to}", `${pad((h + 1) % 24)}:00`);
  const pct = (v: number) => `${(100 * v) / top}%`;
  const describe = (h: InboundHour) => [
    `${range(h.hour)}:`, `${fmtCount(h.offered, locale)} ${t.inboundOffered.toLowerCase()},`,
    `${fmtCount(h.answered, locale)} ${t.inboundAnswered.toLowerCase()},`, `${fmtCount(h.unanswered, locale)} ${t.inboundUnanswered.toLowerCase()}`,
  ].join(" ");
  const tip = active !== null && hours ? hours[active] : null;
  // the Tab stop: the chosen column, else the running hour, else the first column with calls
  const stop = focusHour ?? nowHour ?? (hours ?? []).find((h) => h.offered > 0)?.hour ?? 0;
  const move = (hour: number) => {
    const next = Math.max(0, Math.min(23, hour));
    setFocusHour(next);
    setActive(next);
    document.querySelector<HTMLButtonElement>(`[data-testid="inbound-hours"] [data-hour="${pad(next)}"]`)?.focus();
  };

  return (
    <section aria-labelledby="inbound-hours" className="mt-6 rounded-card border border-p4a-border bg-white p-6" data-testid="inbound-hours">
      <div className="mb-4 flex items-baseline justify-between gap-4">
        <div className="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 id="inbound-hours" className="flex items-start text-panel font-semibold text-p4a-heading" data-hint-anchor="">
            {t.hoursTitle}
            <HeaderHint label={copy.hints.about.replace("{label}", t.hoursTitle)} text={copy.hints.liveHours} />
          </h2>
          {scope ? <p className="text-small text-p4a-muted">{scope}</p> : null}
          {failed && hours && readAt ? (
            <p role="status" className="text-small text-p4a-muted" data-testid="inbound-hours-stale">{t.notUpdatedSince.replace("{time}", timeInZone(readAt, timeZone))}</p>
          ) : null}
        </div>
        <div className="flex shrink-0 items-center gap-6 text-small text-p4a-body">
          <ul className="flex items-center gap-4" aria-label={t.hoursLegend} data-testid="inbound-hours-legend">
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-p4a-deepblue" />{t.inboundAnswered}</li>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-p4a-warning" />{t.inboundUnanswered}</li>
          </ul>
          {/* no prefetch: this card sits on a polled page and would fetch the route again on every refresh (Shell) */}
          <Link href="/reports/inbound?range=today&group=hour" prefetch={false} className="font-semibold text-p4a-deepblue hover:underline">{t.openInbound}</Link>
        </div>
      </div>

      <div className="flex gap-2">
        {/* the axis: 0, the half (when whole) and the top, recessive */}
        <div className="relative w-8 shrink-0 text-right text-caption text-p4a-grey" style={{ height: PLOT_PX }} aria-hidden="true">
          <span className="absolute right-0 top-0 -translate-y-1/2 tabular">{fmtCount(top, locale)}</span>
          {top % 2 === 0 ? <span className="absolute right-0 top-1/2 -translate-y-1/2 tabular">{fmtCount(top / 2, locale)}</span> : null}
          <span className="absolute bottom-0 right-0 translate-y-1/2 tabular">0</span>
        </div>
        <div className="min-w-0 flex-1">
          <div className="relative" style={{ height: PLOT_PX }} data-testid="inbound-hours-plot">
            <div aria-hidden="true" className="absolute inset-x-0 top-0 border-t border-p4a-border" />
            {top % 2 === 0 ? <div aria-hidden="true" className="absolute inset-x-0 top-1/2 border-t border-p4a-border" /> : null}
            <div aria-hidden="true" className="absolute inset-x-0 bottom-0 border-t border-p4a-border" />
            {hours === null && failed ? (
              <p role="status" className="absolute inset-0 flex items-center justify-center text-small text-p4a-muted" data-testid="inbound-hours-failed">{t.hoursUnavailable}</p>
            ) : hours === null ? (
              <div className="absolute inset-0 animate-pulse rounded-input bg-p4a-bgblue/40" data-testid="inbound-hours-loading" />
            ) : !any ? (
              <p className="absolute inset-0 flex items-center justify-center text-small text-p4a-muted" data-testid="inbound-hours-empty">{t.hoursEmpty}</p>
            ) : (
              <div className="absolute inset-0 grid grid-cols-[repeat(24,minmax(0,1fr))]">
                {hours.map((h) => (
                  <button
                    key={h.hour}
                    type="button"
                    aria-label={describe(h)}
                    data-hour={pad(h.hour)}
                    tabIndex={h.hour === stop ? 0 : -1}
                    onKeyDown={(e) => {
                      const to = e.key === "ArrowRight" ? h.hour + 1 : e.key === "ArrowLeft" ? h.hour - 1 : e.key === "Home" ? 0 : e.key === "End" ? 23 : null;
                      if (to !== null) { e.preventDefault(); move(to); }
                    }}
                    onMouseEnter={() => setActive(h.hour)}
                    onMouseLeave={() => setActive((a) => (a === h.hour ? null : a))}
                    onFocus={() => { setActive(h.hour); setFocusHour(h.hour); }}
                    onBlur={() => setActive((a) => (a === h.hour ? null : a))}
                    className={`group flex h-full items-end justify-center ${h.hour === nowHour ? "bg-p4a-bgblue/40" : ""}`}
                  >
                    {h.answered + h.unanswered > 0 ? (
                      <span className="flex w-full max-w-6 flex-col-reverse gap-[2px] opacity-100 group-hover:opacity-80" style={{ height: pct(h.answered + h.unanswered) }}>
                        {h.answered > 0 ? (
                          <span className={`block w-full bg-p4a-deepblue ${h.unanswered === 0 ? "rounded-t-[4px]" : ""}`} style={{ flexGrow: h.answered, flexBasis: 0 }} />
                        ) : null}
                        {h.unanswered > 0 ? (
                          <span className="block w-full rounded-t-[4px] bg-p4a-warning" style={{ flexGrow: h.unanswered, flexBasis: 0 }} />
                        ) : null}
                      </span>
                    ) : null}
                  </button>
                ))}
              </div>
            )}
            {tip ? (
              // beside the hovered column, inside the plot: never over the column itself or the card's title
              <div role="tooltip" data-testid="inbound-hours-tip"
                className="pointer-events-none absolute top-0 z-10 w-max rounded-input border border-p4a-border bg-white px-3 py-2 text-small text-p4a-body shadow-[0_1px_2px_rgba(11,19,61,0.06)]"
                style={tip.hour < 12 ? { left: `calc(${(100 * (tip.hour + 1)) / 24}% + 8px)` } : { right: `calc(${(100 * (24 - tip.hour)) / 24}% + 8px)` }}>
                <p className="text-caption text-p4a-grey">{range(tip.hour)}</p>
                <p><strong className="tabular">{fmtCount(tip.offered, locale)}</strong> {t.inboundOffered.toLowerCase()}</p>
                <p className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-0.5 w-3 bg-p4a-deepblue" /><strong className="tabular">{fmtCount(tip.answered, locale)}</strong> {t.inboundAnswered.toLowerCase()}</p>
                <p className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-0.5 w-3 bg-p4a-warning" /><strong className="tabular">{fmtCount(tip.unanswered, locale)}</strong> {t.inboundUnanswered.toLowerCase()}</p>
                {tip.waiting > 0 ? <p className="pl-5"><strong className="tabular">{fmtCount(tip.waiting, locale)}</strong> {copy.inbound.waiting.toLowerCase()}</p> : null}
                <p className="pl-5">{t.inboundServiceLevel} <strong className="tabular">{fmtPct(tip.serviceLevelPct, locale)}</strong></p>
              </div>
            ) : null}
          </div>
          {/* the hours, the running one marked */}
          <div className="mt-1 grid grid-cols-[repeat(24,minmax(0,1fr))] text-center text-caption text-p4a-grey" aria-hidden="true">
            {Array.from({ length: 24 }, (_, h) => (
              <span key={h} className={`tabular ${h === nowHour ? "font-semibold text-p4a-heading" : ""}`}>{pad(h)}</span>
            ))}
          </div>
        </div>
      </div>

      {/* the chart's table view, for screen readers (Reports → Inbound has the same figures for everyone) */}
      {hours && any ? (
        <table className="sr-only">
          <caption>{t.hoursTitle}</caption>
          <thead>
            <tr><th scope="col">{copy.inbound.hour}</th><th scope="col">{t.inboundOffered}</th><th scope="col">{t.inboundAnswered}</th>
              <th scope="col">{t.inboundUnanswered}</th><th scope="col">{copy.inbound.waiting}</th><th scope="col">{t.inboundServiceLevel}</th></tr>
          </thead>
          <tbody>
            {hours.filter((h) => h.offered > 0).map((h) => (
              <tr key={h.hour}><th scope="row">{range(h.hour)}</th><td>{h.offered}</td><td>{h.answered}</td><td>{h.unanswered}</td><td>{h.waiting}</td><td>{fmtPct(h.serviceLevelPct, locale)}</td></tr>
            ))}
          </tbody>
        </table>
      ) : null}
    </section>
  );
}
