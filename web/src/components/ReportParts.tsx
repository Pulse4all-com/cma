/**
 * Building blocks of the intake reports (B11): the no-permission card, the not-connected state, the
 * grouping switches (Speed to lead, and Inbound since 0008i), the external record link and the
 * Dashboard's Intake row. Server components; the
 * figures arrive from the data layer and lib/reports arranges them. No customer data: ids, counts,
 * codes and links only. Every Intake tile explains itself in a hint, with the text of the matching
 * report header (copy.hints).
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import { keptShare } from "@/lib/callbacks";
import type { CallbacksKept, CrmRecordsDay, InboundGroup, Intake, SpeedToLeadGroup, SpeedToLeadRow } from "@/lib/data";
import {
  fillHint, fmtBusinessMinutes, fmtCount, fmtPct, INBOUND_GROUPS, intakeTotals, nextGroup, nextInboundGroup, recordsOfType, SPEED_TO_LEAD_GROUPS,
  speedFigures,
} from "@/lib/reports";
import { fmtDate, fmtPercent } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { Card, Keycap } from "./primitives";

export { RecordLink } from "./RecordLink";

export function NoReportPermission({ title, body }: { title: string; body: string }) {
  return (
    <Card>
      <h2 className="text-panel font-semibold text-p4a-heading">{title}</h2>
      <p className="mt-2 text-body">{body}</p>
    </Card>
  );
}

/** A source that is not connected: said in words, never shown as 0 */
export function NotConnected({ label, hint }: { label: string; hint: string }) {
  return (
    <span className="text-small text-p4a-muted" title={hint} data-testid="not-connected">
      {label}
    </span>
  );
}

/** Day, market, agent or pipeline as links; G moves to the next one */
export function GroupSwitch({
  group, query, copy,
}: { group: SpeedToLeadGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.speedToLead;
  const labels: Record<SpeedToLeadGroup, string> = { day: t.day, market: t.market, agent: t.agent, pipeline: t.pipeline };
  const next = nextGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {SPEED_TO_LEAD_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/speed-to-lead", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** Day, market, line or hour as links on the Inbound report (addition 0008i); G moves to the next one */
export function InboundGroupSwitch({
  group, query, copy,
}: { group: InboundGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.inbound;
  const labels: Record<InboundGroup, string> = { day: t.day, market: t.market, line: t.line, hour: t.hour };
  const next = nextInboundGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {INBOUND_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/inbound", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** The record in its own system, in a new window; the address comes from the connection's template */
function IntakeTile({
  label, value, hint, info, testId, href, notConnected = false,
}: {
  label: string; value: ReactNode; hint: ReactNode; testId: string; href?: "/reports/speed-to-lead" | "/reports/intake" | "/reports/follow-up";
  /** The explanation behind the label's info mark: the accessible name and the text */
  info: { about: string; text: string };
  /** The value is a not-connected state in words, set smaller than a figure */
  notConnected?: boolean;
}) {
  // The label is the link, stretched over the whole tile, so the tile stays clickable while the
  // info mark next to the label is a button of its own and never sits inside the link
  return (
    <div className={`relative rounded-card border border-p4a-border bg-white p-5 ${href ? "hover:border-p4a-deepblue" : ""}`} data-testid={testId} data-tile="">
      <p className="flex items-start text-caption text-p4a-grey" data-hint-anchor="">
        {href ? <Link href={href} className="after:absolute after:inset-0 after:rounded-card">{label}</Link> : label}
        <HeaderHint label={info.about} text={info.text} />
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
 */
export function IntakeRow({
  intake, records, speed, callbacks, copy, locale, from,
}: { intake: Intake; records: CrmRecordsDay[]; speed: SpeedToLeadRow[]; callbacks: CallbacksKept; copy: Copy; locale: Locale; from: string }) {
  const t = copy.intakeRow;
  const r = copy.reports;
  const totals = intakeTotals(intake.rows, intake.connections);
  const s = speedFigures(speed);
  const n = (x: number) => fmtCount(x, locale);
  const muted = (label: string, hint: string) => <NotConnected label={label} hint={hint} />;
  const h = copy.hints;
  const info = (label: string, text: string) => ({
    about: h.about.replace("{label}", label), text: fillHint(text, { hours: h.officeHours, minutes: callbacks.windowMinutes }, locale),
  });
  const cb = callbacks.total;
  return (
    <section aria-labelledby="intake-row" className="mb-6" data-testid="intake-row">
      <div className="mb-3 flex items-baseline justify-between gap-4">
        <h2 id="intake-row" className="text-panel font-semibold text-p4a-heading">{t.title}</h2>
        <p className="text-caption text-p4a-grey">{t.hint}</p>
      </div>
      <div className="grid grid-cols-4 gap-4 2xl:grid-cols-7">
        <IntakeTile testId="intake-leads" href="/reports/intake" label={t.leads} info={info(t.leads, h.leads)} value={n(totals.formSubmissions ?? 0)} hint={t.leadsHint} />
        <IntakeTile testId="intake-deals" href="/reports/intake" label={t.deals} info={info(t.deals, h.dealsCreatedClosed)} value={n(recordsOfType(records, "deal"))} hint={t.dealsHint} />
        <IntakeTile testId="intake-tickets" href="/reports/intake" label={t.tickets} info={info(t.tickets, h.ticketsCreatedClosed)} value={n(recordsOfType(records, "ticket"))} hint={t.ticketsHint} />
        <IntakeTile
          testId="intake-speed"
          href="/reports/speed-to-lead"
          label={t.speed}
          info={info(t.speed, h.median)}
          value={fmtBusinessMinutes(s.medianBusinessMinutes, locale)}
          hint={<>{t.speedHint}<br />{t.speedDetail.replace("{pct}", fmtPct(s.withinTargetPct, locale)).replace("{open}", n(s.openNotCalled))}</>}
        />
        <IntakeTile
          testId="intake-calls"
          href="/reports/intake"
          label={t.calls}
          info={info(t.calls, h.calls)}
          notConnected={!intake.connections.telephony}
          value={intake.connections.telephony ? n((totals.callsIn ?? 0) + (totals.callsOut ?? 0)) : muted(r.noTelephony, r.noTelephonyHint)}
          hint={intake.connections.telephony ? t.callsHint.replace("{in}", n(totals.callsIn ?? 0)).replace("{out}", n(totals.callsOut ?? 0)) : r.noTelephonyHint}
        />
        <IntakeTile
          testId="intake-shop"
          href="/reports/intake"
          label={t.shop}
          info={info(t.shop, h.shop)}
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
          info={info(t.callbacks, h.cbTile)}
          notConnected={!callbacks.connected}
          value={callbacks.connected ? fmtPercent(keptShare(cb), locale) : muted(r.noCallbacks, r.noCallbacksHint)}
          hint={callbacks.connected
            ? t.callbacksHint.replace("{kept}", n(cb.kept)).replace("{decided}", n(cb.kept + cb.notKept)).replace("{pending}", n(cb.pending))
            : r.noCallbacksHint}
        />
      </div>
      {intake.startDate && from < intake.startDate ? (
        <p className="mt-2 text-caption text-p4a-grey">{t.startNote.replace("{date}", fmtDate(intake.startDate, locale))}</p>
      ) : null}
    </section>
  );
}
