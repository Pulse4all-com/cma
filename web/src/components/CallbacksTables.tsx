import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { keptShare } from "@/lib/callbacks";
import type { Copy, Locale } from "@/lib/copy";
import type { CallbackCounts, CallbackOwner, CallbackWeek } from "@/lib/data";
import { fillHint, fmtCount } from "@/lib/reports";
import { addDays, fmtDate, fmtPercent } from "@/lib/time";

/**
 * Callbacks kept on Reports → Follow-up (addition 0008w, brief N19-A part 4): per ISO week of the span, every week shown
 * (a week without callbacks as zeros), and per person for performance.team. Counts and a share only; every header
 * explains itself in a hint with the tenant's window filled in. The tables scroll inside their card.
 */

const th = "h-10 px-3 py-1 font-semibold";
const td = "h-10 whitespace-nowrap px-3 tabular text-right";
const row = "border-b border-p4a-border last:border-b-0 odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

const ZERO: CallbackCounts = { callbacks: 0, kept: 0, notKept: 0, pending: 0, noContact: 0, noDue: 0 };

/** Every ISO week from `from` (a Monday) to the week of `to`, newest first, with its counts or zeros */
export function CallbackWeeksTable({ weeks, from, to, total, minutes, copy, locale }: {
  weeks: CallbackWeek[]; from: string; to: string; total: CallbackCounts; minutes: number; copy: Copy; locale: Locale;
}) {
  const t = copy.followUp;
  const h = copy.hints;
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={fillHint(text, { hours: h.officeHours, minutes }, locale)} />;
  const n = (x: number) => fmtCount(x, locale);
  const all: CallbackWeek[] = [];
  for (let w = from; w <= to; w = addDays(w, 7)) all.push(weeks.find((x) => x.weekStart === w) ?? { weekStart: w, ...ZERO });
  all.reverse();
  const cells = (c: CallbackCounts) => (
    <>
      <td className={td}>{n(c.callbacks)}</td>
      <td className={td}>{n(c.kept)}</td>
      <td className={td}>{n(c.notKept)}</td>
      <td className={td}>{n(c.pending)}</td>
      <td className={`${td} font-semibold`}>{fmtPercent(keptShare(c), locale)}</td>
      <td className={td}>{n(c.noContact)}</td>
      <td className={td}>{n(c.noDue)}</td>
    </>
  );
  return (
    <div className="overflow-x-auto" data-testid="callbacks-weeks-scroll" role="region" aria-label={t.callbacksTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="callbacks-weeks">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.week}>{hint(t.week, h.cbWeek)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbCallbacks}>{hint(t.cbCallbacks, h.cbCallbacks)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbKept}>{hint(t.cbKept, h.cbKept)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbNotKept}>{hint(t.cbNotKept, h.cbNotKept)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbPending}>{hint(t.cbPending, h.cbPending)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbShare}>{hint(t.cbShare, h.cbShare)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbNoContact}>{hint(t.cbNoContact, h.cbNoContact)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbNoDue}>{hint(t.cbNoDue, h.cbNoDue)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {all.map((w) => (
            <tr key={w.weekStart} className={row} data-testid="callbacks-week">
              <td className="h-10 whitespace-nowrap px-3 font-semibold">{fmtDate(w.weekStart, locale)}</td>
              {cells(w)}
            </tr>
          ))}
          <tr className="text-p4a-body" data-testid="callbacks-total">
            <td className="h-10 whitespace-nowrap px-3 font-semibold">{copy.reports.total}</td>
            {cells(total)}
          </tr>
        </tbody>
      </table>
    </div>
  );
}

/** Per person by name, never ranked; the owners without a person as one row; the total last */
export function CallbackOwnersTable({ rows, minutes, copy, locale }: { rows: CallbackOwner[]; minutes: number; copy: Copy; locale: Locale }) {
  const t = copy.followUp;
  const h = copy.hints;
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={fillHint(text, { hours: h.officeHours, minutes }, locale)} />;
  const n = (x: number) => fmtCount(x, locale);
  const name = (o: CallbackOwner) => o.kind === "total" ? copy.reports.total
    : o.kind === "notLinked" ? (o.unlinkedOwners === 1 ? t.cbNotLinkedOne : t.cbNotLinkedMany.replace("{n}", n(o.unlinkedOwners ?? 0)))
    : o.name ?? t.notMapped;
  return (
    <div className="overflow-x-auto" data-testid="callbacks-owners-scroll" role="region" aria-label={t.callbacksByOwnerTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="callbacks-owners">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.person}>{hint(t.person, h.cbPerson)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbCallbacks}>{hint(t.cbCallbacks, h.cbCallbacks)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbKept}>{hint(t.cbKept, h.cbKept)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbNotKept}>{hint(t.cbNotKept, h.cbNotKept)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbPending}>{hint(t.cbPending, h.cbPending)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbShare}>{hint(t.cbShare, h.cbShare)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.cbNoContact}>{hint(t.cbNoContact, h.cbNoContact)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((o) => (
            <tr key={o.kind === "person" ? o.userId ?? "" : o.kind} className={o.kind === "total" ? "text-p4a-body" : row}
              data-testid={o.kind === "person" ? "callbacks-owner" : o.kind === "notLinked" ? "callbacks-owner-not-linked" : "callbacks-owner-total"}>
              <td className={`h-10 whitespace-nowrap px-3 ${o.kind === "notLinked" ? "text-p4a-muted" : "font-semibold"}`}>{name(o)}</td>
              <td className={td}>{n(o.callbacks)}</td>
              <td className={td}>{n(o.kept)}</td>
              <td className={td}>{n(o.notKept)}</td>
              <td className={td}>{n(o.pending)}</td>
              <td className={`${td} font-semibold`}>{fmtPercent(keptShare(o), locale)}</td>
              <td className={td}>{n(o.noContact)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
