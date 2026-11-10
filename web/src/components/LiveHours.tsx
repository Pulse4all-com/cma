"use client";

/**
 * Inbound today by hour on the Live board (the Live board's UX pass, 10 November 2026; Martin: "include some nice
 * charts"): a column per hour, 00 to 23, of today's answered and unanswered inbound calls, from Reports → Inbound's own
 * read (GET /api/v1/reports/inbound?group=hour for today: each call's hour in its line's zone, the report's figures), so
 * the board adds no read to its 10-second poll: this one is fetched after the first paint and once a minute while the tab
 * is visible, and once more when it comes back. For a holder of reports.view or performance.team (the report's
 * permission); the board passes it only then.
 *
 * Built by the dataviz rules and docs/style/Pulse4all-Style.md 7.7, in plain HTML and CSS as the Dashboard's charts: one
 * axis (counts), columns at most 24px wide with a 4px rounded data end and a 2px surface gap between the stacked parts,
 * hairline solid gridlines, axis labels 12px Footnote Grey. Answered is Deep Blue and unanswered Warning amber
 * ("needs attention"); the pair passes the palette validator's lightness, chroma, colour-blind and normal-vision checks on
 * white, and amber's contrast warning is met by the legend, the tooltip and the table view. Waiting calls (only ever
 * in the running hour) are in the tooltip, not a third colour. Every column is focusable and shows the same tooltip on
 * focus as on hover; the values are also in a table for screen readers and on Reports → Inbound. The running hour (in
 * the viewer's zone) is marked under the axis. While the read is under way the plot keeps its size, so nothing jumps.
 */
import Link from "next/link";
import { useEffect, useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { InboundService } from "@/lib/data";
import { inboundHours, LIVE_POLL_TIMEOUT_MS, niceCeiling, type InboundHour, type LiveHints } from "@/lib/live";
import { fmtCount, fmtPct } from "@/lib/reports";
import { hourInZone } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";

/** How often the hours are read again while the tab is visible: they change by the call, not by the second */
export const LIVE_HOURS_MS = 60_000;

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

  useEffect(() => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const load = async () => {
      try {
        const res = await fetch(`/api/v1/reports/inbound?from=${date}&to=${date}&group=hour`,
          { cache: "no-store", signal: AbortSignal.timeout(LIVE_POLL_TIMEOUT_MS) });
        // not the report's permission after all, or no telephony: the board shows no chart rather than an empty one
        if (res.status === 403) { if (!stopped) setHidden(true); return; }
        if (!res.ok) return;
        const body = (await res.json()) as { data: InboundService };
        if (stopped) return;
        if (!body.data.telephony) { setHidden(true); return; }
        setHours(inboundHours(body.data.rows));
        setNowHour(hourInZone(new Date(), timeZone));
      } catch {
        // a failed read keeps the last chart; the board's own line says when its figures are old
      }
    };
    const schedule = () => {
      timer = setTimeout(async () => {
        if (!document.hidden) await load();
        if (!stopped) schedule();
      }, LIVE_HOURS_MS);
    };
    void load();
    schedule();
    const onVisibility = () => { if (document.visibilityState === "visible") void load(); };
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

  return (
    <section aria-labelledby="inbound-hours" className="rounded-card border border-p4a-border bg-white p-6" data-testid="inbound-hours">
      <div className="mb-4 flex items-baseline justify-between gap-4">
        <div className="flex min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 id="inbound-hours" className="flex items-start text-panel font-semibold text-p4a-heading" data-hint-anchor="">
            {t.hoursTitle}
            <HeaderHint label={copy.hints.about.replace("{label}", t.hoursTitle)} text={copy.hints.liveHours} />
          </h2>
          {scope ? <p className="text-small text-p4a-muted">{scope}</p> : null}
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
            {hours === null ? (
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
                    onMouseEnter={() => setActive(h.hour)}
                    onMouseLeave={() => setActive((a) => (a === h.hour ? null : a))}
                    onFocus={() => setActive(h.hour)}
                    onBlur={() => setActive((a) => (a === h.hour ? null : a))}
                    className={`group flex h-full items-end justify-center outline-none ${h.hour === nowHour ? "bg-p4a-bgblue/40" : ""} focus-visible:bg-p4a-bgblue`}
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
              <div role="tooltip" data-testid="inbound-hours-tip"
                className="pointer-events-none absolute bottom-full z-10 mb-2 w-max rounded-input border border-p4a-border bg-white px-3 py-2 text-small text-p4a-body shadow-[0_1px_2px_rgba(11,19,61,0.06)]"
                style={tip.hour < 3 ? { left: `${(100 * tip.hour) / 24}%` } : tip.hour > 20 ? { right: `${(100 * (23 - tip.hour)) / 24}%` } : { left: `${(100 * (tip.hour + 0.5)) / 24}%`, transform: "translateX(-50%)" }}>
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
