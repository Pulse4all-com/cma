/**
 * The Dashboard's Intake row (B11), in a file of its own since 12 November 2026: a server component whose two reads
 * arrive on their own (lib/head-start, components/HeadStart), which the client components that share ReportParts
 * must not pull in. No customer data: counts and codes only. Every tile explains itself in a hint, with the text of
 * the matching report header (copy.hints).
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import { keptShare } from "@/lib/callbacks";
import type { CallbacksKept, CrmRecordsDay, Intake, SpeedToLeadRow } from "@/lib/data";
import { blankNumbers, type Head } from "@/lib/head-start";
import { fillHint, fmtBusinessMinutes, fmtCount, fmtPct, intakeTotals, recordsOfType, speedFigures } from "@/lib/reports";
import { fmtDate, fmtPercent } from "@/lib/time";
import { metricsHref } from "@/lib/metrics";
import { HeaderHint } from "./HeaderHint";
import { Part } from "./HeadStart";
import { NotConnected } from "./ReportParts";

/** One tile of the row: the label is the link to its report, the info mark its hint */
function IntakeTile({
  label, value, hint, info, testId, href, notConnected = false, waiting = false, infoWaits = false,
}: {
  label: string; value: ReactNode; hint: ReactNode; testId: string; href?: "/reports/speed-to-lead" | "/reports/intake" | "/reports/follow-up";
  /** The explanation behind the label's info mark: the accessible name, the text and, for tenant.configure, "How this is computed" */
  info: { about: string; text: string; more?: { href: string; label: string } };
  /** The value is a not-connected state in words, set smaller than a figure */
  notConnected?: boolean;
  /** The tile's read is on its way: its figure is an outline */
  waiting?: boolean;
  /** The hint's own number is on its way too: the info mark keeps its place, unseen and out of reach, never a dash for a value */
  infoWaits?: boolean;
}) {
  // The label is the link, stretched over the whole tile, so the tile stays clickable while the
  // info mark next to the label is a button of its own and never sits inside the link
  return (
    <div className={`relative rounded-card border border-p4a-border bg-white p-5 ${href ? "hover:border-p4a-deepblue" : ""}`} data-testid={testId} data-tile=""
      {...(waiting ? { "aria-busy": true, "data-tile-waiting": "" } : {})}>
      <p className="flex items-start text-caption text-p4a-grey" data-hint-anchor="">
        {href ? <Link href={href} className="after:absolute after:inset-0 after:rounded-card">{label}</Link> : label}
        {infoWaits
          ? <span className="invisible" aria-hidden="true"><HeaderHint label={info.about} text={info.text} more={info.more} /></span>
          : <HeaderHint label={info.about} text={info.text} more={info.more} />}
      </p>
      <div className={notConnected ? "mt-2 text-body font-semibold" : "tabular mt-1 text-title font-bold text-p4a-heading"}>{value}</div>
      <div className="mt-1 text-small text-p4a-muted">{hint}</div>
    </div>
  );
}

/**
 * The Dashboard's Intake row for the selected period: leads (counted form submissions), deals and
 * tickets created (cma.crm_records_per_day, the 0006 Dashboard read), speed to lead over the period's
 * lead deals (median business minutes, % within target, open not called), calls and the shop's
 * orders, or the not-connected state of either; since addition 0008w the callbacks kept (KPI 5), or
 * "No callback type set" while the tenant counts none.
 *
 * Since 12 November 2026 the row's two reads arrive on their own (lib/head-start): the counts (the intake, the records
 * created and the callbacks kept, one transaction) and the speed to lead (the dearest read of the page, its own). The
 * row's frame, the tiles' labels and their hints are drawn at once; a read still on its way shows its tiles as
 * outlines of the same size, so nothing moves when the figures land.
 */
export function IntakeRow({
  counts, speed, k, copy, locale, from, canOpenMetrics = false,
}: { counts: Head<{ intake: Intake; records: CrmRecordsDay[]; callbacks: CallbacksKept }>; speed: Head<SpeedToLeadRow[]>;
  /** What the reads are of (the period): a boundary's key, so another period shows its outlines at once */
  k: string; copy: Copy; locale: Locale; from: string;
  /** True for a holder of tenant.configure: each tile's hint links to its entry on Configuration → Metrics */
  canOpenMetrics?: boolean;
}) {
  const t = copy.intakeRow;
  const r = copy.reports;
  const n = (x: number) => fmtCount(x, locale);
  const muted = (label: string, hint: string) => <NotConnected label={label} hint={hint} />;
  const h = copy.hints;
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure. minutes: the
  // callback window, which only the callbacks' hint names
  const info = (label: string, text: string, key?: string, minutes?: number | null) => ({
    about: h.about.replace("{label}", label), text: fillHint(text, { hours: h.officeHours, minutes }, locale),
    more: key && canOpenMetrics ? { href: metricsHref(key), label: h.howComputed } : undefined,
  });
  // a tile whose read is on its way: its label, its info mark and its hint's words in place, the figure an outline; a
  // number in the hint is left blank at a number's width (lib/head-start blankNumbers), so the lines wrap as they will
  // (a hint that names a number of its own, the callbacks' window, keeps its mark's place but cannot be opened yet)
  // the label is already the link to the tile's report: it depends on no figure
  const waiting = (testId: string, label: string, hint: ReactNode, text: string, key: string, href: "/reports/speed-to-lead" | "/reports/intake" | "/reports/follow-up" = "/reports/intake") =>
    <IntakeTile testId={testId} href={href} label={label} info={info(label, text, key)} infoWaits={/\{[a-z]+\}/.test(text.replaceAll("{hours}", ""))}
      value={<TileWait />} hint={hint} waiting />;
  const blank = (text: string) => blankNumbers(text).map((part, i) => (part.blank ? <span key={i} className="invisible">{part.text}</span> : part.text));
  return (
    <section aria-labelledby="intake-row" className="mb-8" data-testid="intake-row">
      <div className="mb-3 flex items-baseline justify-between gap-4">
        <h2 id="intake-row" className="text-panel font-semibold text-p4a-heading">{t.title}</h2>
        <p className="text-caption text-p4a-grey">{t.hint}</p>
      </div>
      <div className="relative grid grid-cols-4 gap-4 2xl:grid-cols-7">
        <Part head={counts} k={`counts-a|${k}`} fallback={<>
          {waiting("intake-leads", t.leads, t.leadsHint, h.leads, "dashboard.intake.leads")}{waiting("intake-deals", t.deals, t.dealsHint, h.dealsCreatedClosed, "dashboard.intake.deals_created")}
          {waiting("intake-tickets", t.tickets, t.ticketsHint, h.ticketsCreatedClosed, "dashboard.intake.tickets_created")}
        </>}>
          {({ intake, records }) => {
            const totals = intakeTotals(intake.rows, intake.connections);
            return (
              <>
                <IntakeTile testId="intake-leads" href="/reports/intake" label={t.leads} info={info(t.leads, h.leads, "dashboard.intake.leads")} value={n(totals.formSubmissions ?? 0)} hint={t.leadsHint} />
                <IntakeTile testId="intake-deals" href="/reports/intake" label={t.deals} info={info(t.deals, h.dealsCreatedClosed, "dashboard.intake.deals_created")} value={n(recordsOfType(records, "deal"))} hint={t.dealsHint} />
                <IntakeTile testId="intake-tickets" href="/reports/intake" label={t.tickets} info={info(t.tickets, h.ticketsCreatedClosed, "dashboard.intake.tickets_created")} value={n(recordsOfType(records, "ticket"))} hint={t.ticketsHint} />
              </>
            );
          }}
        </Part>
        <Part head={speed} k={`speed|${k}`} fallback={waiting("intake-speed", t.speed, <>{t.speedHint}<br />{blank(t.speedDetail)}</>, h.median, "dashboard.intake.speed_to_lead", "/reports/speed-to-lead")}>
          {(rows) => {
            const s = speedFigures(rows);
            return (
              <IntakeTile
                testId="intake-speed"
                href="/reports/speed-to-lead"
                label={t.speed}
                info={info(t.speed, h.median, "dashboard.intake.speed_to_lead")}
                value={fmtBusinessMinutes(s.medianBusinessMinutes, locale)}
                hint={<>{t.speedHint}<br />{t.speedDetail.replace("{pct}", fmtPct(s.withinTargetPct, locale)).replace("{open}", n(s.openNotCalled))}</>}
              />
            );
          }}
        </Part>
        <Part head={counts} k={`counts-b|${k}`} fallback={<>
          {waiting("intake-calls", t.calls, blank(t.callsHint), h.calls, "dashboard.intake.calls")}{waiting("intake-shop", t.shop, blank(t.shopHint), h.shop, "dashboard.intake.first_orders")}
          {waiting("intake-callbacks", t.callbacks, blank(t.callbacksHint), h.cbTile, "dashboard.intake.callbacks_kept", "/reports/follow-up")}
        </>}>
          {({ intake, callbacks }) => {
            const totals = intakeTotals(intake.rows, intake.connections);
            const cb = callbacks.total;
            return (
              <>
                <IntakeTile
                  testId="intake-calls"
                  href="/reports/intake"
                  label={t.calls}
                  info={info(t.calls, h.calls, "dashboard.intake.calls")}
                  notConnected={!intake.connections.telephony}
                  value={intake.connections.telephony ? n((totals.callsIn ?? 0) + (totals.callsOut ?? 0)) : muted(r.noTelephony, r.noTelephonyHint)}
                  hint={intake.connections.telephony ? t.callsHint.replace("{in}", n(totals.callsIn ?? 0)).replace("{out}", n(totals.callsOut ?? 0)) : r.noTelephonyHint}
                />
                <IntakeTile
                  testId="intake-shop"
                  href="/reports/intake"
                  label={t.shop}
                  info={info(t.shop, h.shop, "dashboard.intake.first_orders")}
                  notConnected={!intake.connections.commerce}
                  value={intake.connections.commerce ? n(totals.firstOrders ?? 0) : muted(r.noShop, r.noShopHint)}
                  hint={intake.connections.commerce
                    ? t.shopHint.replace("{customers}", n(totals.newCustomers ?? 0)).replace("{repeat}", n(totals.repeatOrders ?? 0)).replace("{renewals}", n(totals.renewals ?? 0))
                    : r.noShopHint}
                />
                <IntakeTile
                  testId="intake-callbacks"
                  href="/reports/follow-up"
                  label={t.callbacks}
                  info={info(t.callbacks, h.cbTile, "dashboard.intake.callbacks_kept", callbacks.windowMinutes)}
                  notConnected={!callbacks.connected}
                  value={callbacks.connected ? fmtPercent(keptShare(cb), locale) : muted(r.noCallbacks, r.noCallbacksHint)}
                  hint={callbacks.connected
                    ? t.callbacksHint.replace("{kept}", n(cb.kept)).replace("{decided}", n(cb.kept + cb.notKept)).replace("{pending}", n(cb.pending))
                    : r.noCallbacksHint}
                />
              </>
            );
          }}
        </Part>
        {/* the note that the period starts before the intake's start date, with the counts: it hangs under the tiles in
            the row's own bottom margin, so it takes no height and nothing moves when it lands */}
        <Part head={counts} k={`note|${k}`} fallback={null}>
          {({ intake }) => (intake.startDate && from < intake.startDate ? (
            <p className="absolute left-0 top-full mt-2 text-caption text-p4a-grey" data-testid="intake-start-note">{t.startNote.replace("{date}", fmtDate(intake.startDate, locale))}</p>
          ) : null)}
        </Part>
      </div>
    </section>
  );
}

/** A figure on its way: an outline of a figure's height, so the tile keeps its size */
function TileWait() {
  return <span className="inline-block w-16 animate-pulse rounded-input bg-p4a-border" aria-hidden="true">&nbsp;</span>;
}
