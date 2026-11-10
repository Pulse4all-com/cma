/**
 * The Live board's inbound parts (addition 0008i, brief B15): today's inbound tiles (inbound, answered,
 * unanswered share, service level, average time to answer, waiting now) at the top, and
 * the missed calls not called back (MissedCallbacks), the board's last section since addition 0008z
 * (Martin, 20 October 2026), one row per caller, oldest first, with the line, market, reason, the
 * time of the latest missed call, the waiting time in office time of the line's market, how often the
 * caller was missed and a link icon only when the connection has a call link template; then the count
 * of anonymous missed calls. A server component: the page's poll (LiveRefresh) reads it again every 10
 * seconds. Ids, codes, line names and counts only: no number, no name, never the caller's hash. A tenant
 * without telephony sees "No telephony connected", never 0. Tiles are white cards with Deep Blue figures
 * and Muted labels (docs/style/Pulse4all-Style.md 7.3: radius 15px, padding 24px), three to a row at
 * 1280 px and six from 1536 px, as the outbound row (OutboundLive) and the follow-up strip; no figure is a filled red tile. The table has zebra rows and a hover row
 * (7.6).
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { InboundNow, MissedCallback } from "@/lib/data";
import { callbackWaiting, INBOUND_TILES, inboundTileValue, type InboundTileKey } from "@/lib/live";
import { fillHint, fmtAnswerSeconds, fmtBusinessMinutes, fmtCount, fmtPct } from "@/lib/reports";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { metricsHref } from "@/lib/metrics";
import { HintLabel } from "./HintLabel";
import { NotConnected, RecordLink } from "./ReportParts";
import { Card } from "./primitives";

export function Tile({ label, info, value, testId }: {
  label: string;
  /** The hint behind the info mark; more: "How this is computed" to the figure's catalog entry, for tenant.configure only */
  info: { about: string; text: string; more?: { href: string; label: string } }; value: ReactNode; testId: string;
}) {
  return (
    <div className="rounded-card border border-p4a-border bg-white p-6" data-testid={testId} data-tile="">
      <p className="flex items-start text-small text-p4a-muted" data-hint-anchor="">
        {label}
        <HeaderHint label={info.about} text={info.text} more={info.more} />
      </p>
      <div className="tabular mt-1 whitespace-nowrap text-title font-bold text-p4a-heading">{value}</div>
    </div>
  );
}

/** The words the inbound tiles and the missed callers use: a slice of the copy object (night N06), never the whole */
export type InboundCopy = Pick<Copy, "live" | "hints" | "inbound" | "reports">;

export function InboundLive({ inbound, copy, locale, canOpenMetrics = false, scope }: {
  inbound: InboundNow; copy: InboundCopy; locale: Locale;
  /** True for a holder of tenant.configure: each tile's hint links to its entry on Configuration -> Metrics */
  canOpenMetrics?: boolean;
  /** A caption under the title on what the figures cover (a contact center's Live board: all lines, addition 0008zv) */
  scope?: string;
}) {
  const t = copy.live;
  const h = copy.hints;
  const today = inbound.today;
  const fill = (text: string) => fillHint(text, {
    hours: h.officeHours, seconds: today?.serviceLevelSeconds ?? null, minutes: today?.waitingMaxMinutes ?? null, days: inbound.lookbackDays,
  }, locale);
  const info = (label: string, text: string, key?: string) =>
    ({ about: h.about.replace("{label}", label), text: fill(text), more: key && canOpenMetrics ? { href: metricsHref(key), label: h.howComputed } : undefined });

  const tiles: Record<InboundTileKey, { label: string; hint: string; metric: string }> = {
    offered: { label: t.inboundOffered, hint: h.liveOffered, metric: "live.inbound.offered" },
    answered: { label: t.inboundAnswered, hint: h.liveAnswered, metric: "live.inbound.answered" },
    unansweredPct: { label: t.inboundUnanswered, hint: h.unansweredPct, metric: "live.inbound.unanswered_share" },
    serviceLevel: { label: t.inboundServiceLevel, hint: h.serviceLevel, metric: "live.inbound.service_level" },
    avgAnswer: { label: t.inboundAvgAnswer, hint: h.avgAnswer, metric: "live.inbound.avg_answer" },
    waitingNow: { label: t.inboundWaitingNow, hint: h.liveWaitingNow, metric: "live.inbound.waiting_now" },
  };
  const shown = (key: InboundTileKey): ReactNode => {
    if (!today) return "–";
    const v = inboundTileValue(today, key);
    if (v.kind === "count") return fmtCount(v.value, locale);
    if (v.kind === "pct") return fmtPct(v.value, locale);
    return fmtAnswerSeconds(v.value, locale);
  };

  return (
    <section aria-labelledby="inbound-today" className="flex flex-col gap-4" data-testid="inbound-live">
      <div>
        <h2 id="inbound-today" className="text-panel font-semibold text-p4a-heading">{t.inboundTitle}</h2>
        {scope && inbound.telephony ? <p className="mt-1 text-small text-p4a-muted" data-testid="inbound-scope">{scope}</p> : null}
      </div>
      {!inbound.telephony ? (
        <Card>
          <p className="text-body" data-testid="inbound-not-connected">
            <NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noTelephonyHint}</span>
          </p>
        </Card>
      ) : (
        <div className="grid grid-cols-3 gap-4 2xl:grid-cols-6" data-testid="inbound-tiles">
          {INBOUND_TILES.map((key) => (
            <Tile key={key} testId={`inbound-${key}`} label={tiles[key].label} info={info(tiles[key].label, tiles[key].hint, tiles[key].metric)} value={shown(key)} />
          ))}
        </div>
      )}
    </section>
  );
}

/**
 * The missed calls not called back, the Live board's last section (addition 0008z): nothing while the tenant has no
 * telephony, since the inbound part above already says so
 */
export function MissedCallbacks({ inbound, copy, locale, timeZone, scope }: {
  inbound: InboundNow; copy: InboundCopy; locale: Locale; timeZone: string;
  /** A caption after the intro on what the list covers (a contact center's Live board: all lines, addition 0008zv) */
  scope?: string;
}) {
  if (!inbound.telephony) return null;
  const t = copy.live;
  const h = copy.hints;
  const today = inbound.today;
  const fill = (text: string) => fillHint(text, {
    hours: h.officeHours, seconds: today?.serviceLevelSeconds ?? null, minutes: today?.waitingMaxMinutes ?? null, days: inbound.lookbackDays,
  }, locale);
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={fill(text)} />;
  const todayKey = dateKeyInZone(new Date(), timeZone);
  const missedAt = (r: MissedCallback) => {
    const day = dateKeyInZone(r.startedAt, timeZone);
    return `${day === todayKey ? "" : `${fmtDate(day, locale, "compact")} `}${fmtTime(r.startedAt, timeZone, locale)}`;
  };
  const th = "h-10 px-3 py-1 font-semibold";
  const td = "h-10 whitespace-nowrap px-3";

  return (
    <section aria-labelledby="missed-title" data-testid="missed-live">
      <Card>
        <h2 id="missed-title" className="mb-1 flex items-start text-panel font-semibold text-p4a-heading" data-hint-anchor="">
          {t.missedTitle}
          {hint(t.missedTitle, h.missedCallbacks)}
        </h2>
        <p className="mb-4 text-small text-p4a-muted">{t.missedIntro}{scope ? <> <span data-testid="missed-scope">{scope}</span></> : null}</p>
        {inbound.callbacks.length === 0 ? (
          <p className="text-body text-p4a-muted">{fill(t.missedEmpty)}</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full border-collapse text-body leading-table" data-testid="missed-callbacks">
              <thead>
                <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
                  <th className={th}><HintLabel label={t.missedLine}>{hint(t.missedLine, h.missedLine)}</HintLabel></th>
                  <th className={th}><HintLabel label={t.missedMarket}>{hint(t.missedMarket, h.missedMarket)}</HintLabel></th>
                  <th className={th}><HintLabel label={t.missedReason}>{hint(t.missedReason, h.missedReason)}</HintLabel></th>
                  <th className={th}><HintLabel label={t.missedAt}>{hint(t.missedAt, h.missedAt)}</HintLabel></th>
                  <th className={`${th} text-right`}><HintLabel label={t.missedWaiting}>{hint(t.missedWaiting, h.missedWaiting)}</HintLabel></th>
                  <th className={`${th} text-right`}><HintLabel label={t.missedTimes}>{hint(t.missedTimes, h.missedTimes)}</HintLabel></th>
                  <th className={`${th} w-12`}><span className="sr-only">{t.missedLink}</span></th>
                </tr>
              </thead>
              <tbody>
                {inbound.callbacks.map((r) => {
                  const w = callbackWaiting(r);
                  return (
                    <tr key={r.callId} className="border-b border-p4a-border last:border-b-0 odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                      <td className={td}>{r.lineName ?? copy.inbound.unknownLine}</td>
                      <td className={td}>{r.market === "unknown" ? copy.reports.unknownMarket : r.market}</td>
                      <td className={td}>{r.reasonCode === "unknown" && r.reasonLabel === "unknown" ? copy.inbound.unknownReason : r.reasonLabel}</td>
                      <td className={`${td} tabular`}>{missedAt(r)}</td>
                      <td className={`${td} tabular text-right`}>
                        {w.kind === "business"
                          ? w.closed
                            // No office time has passed since the call: the market is closed now, so "0 min" would read as
                            // "just missed"; the time since the call sits in the title (the IT audit of 17 October 2026)
                            ? <span className="text-p4a-muted" data-testid="missed-closed" title={t.missedClosedTitle.replace("{time}", fmtBusinessMinutes(Math.floor(r.waitingSeconds / 60), locale))}>{t.missedClosed}</span>
                            : fmtBusinessMinutes(Math.floor(w.seconds / 60), locale)
                          : <span className="text-p4a-muted" title={t.missedSinceCall}>{fmtBusinessMinutes(Math.floor(w.seconds / 60), locale)}</span>}
                      </td>
                      <td className={`${td} tabular text-right`}>{fmtCount(r.missedCount, locale)}</td>
                      <td className={`${td} text-right`}>
                        {r.recordUrl ? <RecordLink url={r.recordUrl} label={t.openCall.replace("{id}", r.sourceId)} /> : null}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        {inbound.anonymousCount > 0 ? (
          <p className="mt-4 text-small text-p4a-muted" data-testid="missed-anonymous">
            {fill(t.anonymous.replace("{n}", fmtCount(inbound.anonymousCount, locale)))}
          </p>
        ) : null}
      </Card>
    </section>
  );
}
