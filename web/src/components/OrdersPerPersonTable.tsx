/**
 * Orders per person's table (addition 0008u; brief N19-A part 2): one row per person, sorted by name and never
 * ranked, the credited orders of owner ids without a person last as one row with how many owner ids that is, then
 * the total. The credited orders carry an inline bar scaled to the column's largest value, in Deep Blue
 * (docs/style/Pulse4all-Style.md 7.7), never with text on it (7.8); then the credited orders per level and the
 * median days from the first touch. Rows follow 7.6. Staff names only: no owner id, no customer.
 */
import type { Copy, Locale } from "@/lib/copy";
import type { OrderPerson } from "@/lib/data";
import { fmtDays } from "@/lib/first-orders";
import { barShare, fmtCount } from "@/lib/reports";
import { HeaderHint } from "./HeaderHint";

export function OrdersPerPersonTable({ rows, total, hints, copy, locale }: {
  rows: OrderPerson[]; total: OrderPerson; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.ordersPerPerson;
  const f = copy.firstOrders;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const largest = Math.max(0, ...rows.map((r) => r.orders));
  // headers may wrap over two lines (bottom-aligned), so the eight columns fit the card at 1280 px
  const th = "h-10 px-2 py-1 align-bottom font-semibold";
  const td = "h-10 whitespace-nowrap px-2 tabular text-right";
  const nameOf = (p: OrderPerson) => (p.kind === "person" ? p.name ?? ""
    : p.unlinkedOwners === 1 ? t.notLinkedOne : p.unlinkedOwners ? t.notLinkedMany.replace("{n}", n(p.unlinkedOwners)) : t.notLinkedNone);
  const cells = (p: OrderPerson, bar: boolean) => (
    <>
      <td className={`${td} ${p.kind === "total" ? "font-semibold" : ""}`}>
        <span className="block">{n(p.orders)}</span>
        {bar ? (
          <span aria-hidden="true" className="ml-auto mt-1 block h-1.5 w-16 overflow-hidden rounded-full bg-p4a-neutral-surface" data-bar="">
            <span className="block h-1.5 rounded-full bg-p4a-deepblue" style={{ width: `${(barShare(p.orders, largest) * 100).toFixed(1)}%` }} />
          </span>
        ) : null}
      </td>
      <td className={td}>{n(p.leadDeal)}</td>
      <td className={td}>{n(p.conversation)}</td>
      <td className={td}>{n(p.email)}</td>
      <td className={td}>{n(p.phoneMatch)}</td>
      <td className={td}>{n(p.otherLevels)}</td>
      <td className={td}>{fmtDays(p.daysMedian, locale)}</td>
    </>
  );
  return (
    <div className="overflow-x-auto" data-testid="orders-person-scroll" role="region" aria-label={t.title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="orders-person-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={`${th} w-48`}>{t.person}{hint(t.person, hints.foPerson!)}</th>
            <th className={`${th} text-right`}>{t.orders}{hint(t.orders, hints.foPersonOrders!)}</th>
            <th className={`${th} text-right`}>{f.level_lead_deal}{hint(f.level_lead_deal, hints.foPersonLevel!)}</th>
            <th className={`${th} text-right`}>{f.level_conversation}{hint(f.level_conversation, hints.foPersonLevel!)}</th>
            <th className={`${th} text-right`}>{f.level_email}{hint(f.level_email, hints.foPersonLevel!)}</th>
            <th className={`${th} text-right`}>{f.level_phone_match}{hint(f.level_phone_match, hints.foPersonLevel!)}</th>
            <th className={`${th} text-right`}>{t.other}{hint(t.other, hints.foPersonLevel!)}</th>
            <th className={`${th} text-right`}>{f.days}{hint(f.days, hints.foPersonDays!)}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => (
            <tr key={p.kind === "person" ? p.userId : p.kind} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50"
              data-testid={p.kind === "notLinked" ? "orders-person-not-linked" : "orders-person-row"}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{nameOf(p)}</td>
              {cells(p, true)}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body" data-testid="orders-person-total">
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{copy.reports.total}</td>
            {cells(total, false)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
