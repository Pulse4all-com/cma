/**
 * Attempts per agent's table (addition 0008y, 19 October 2026): one row per deal owner, sorted by name and never ranked
 * (README Decision log, 7 and 14 October 2026), the deals of owner ids without a person (or without an owner) last as
 * one row with how many owner ids that is, then the total. The attempts carry an inline bar scaled to the column's
 * largest value, in Deep Blue (docs/style/Pulse4all-Style.md 7.7), never with text on it (7.8). Rows follow 7.6. Staff
 * names only: no owner id, no customer.
 */
import type { Copy, Locale } from "@/lib/copy";
import type { AttemptPerson } from "@/lib/data";
import { fmtAttempts, firstReachShare } from "@/lib/attempts";
import { barShare, fmtCount, fmtShare } from "@/lib/reports";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";

export function AttemptsPerAgentTable({ rows, total, hints, copy, locale }: {
  rows: AttemptPerson[]; total: AttemptPerson; hints: Record<string, string>; copy: Copy; locale: Locale;
}) {
  const t = copy.attemptsPerAgent;
  const a = copy.attempts;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const largest = Math.max(0, ...rows.map((r) => r.attempts));
  const th = "h-10 px-2 py-1 align-bottom font-semibold";
  const td = "h-10 whitespace-nowrap px-2 tabular text-right";
  const nameOf = (p: AttemptPerson) => (p.kind === "person" ? p.name ?? ""
    : p.unlinkedOwners === 1 ? t.notLinkedOne : p.unlinkedOwners ? t.notLinkedMany.replace("{n}", n(p.unlinkedOwners)) : t.notLinkedNone);
  const cells = (p: AttemptPerson, bar: boolean) => (
    <>
      <td className={td}>{n(p.deals)}</td>
      <td className={td}>{n(p.attempted)}</td>
      <td className={`${td} ${p.kind === "total" ? "font-semibold" : ""}`}>
        <span className="block">{n(p.attempts)}</span>
        {bar ? (
          <span aria-hidden="true" className="ml-auto mt-1 block h-1.5 w-16 overflow-hidden rounded-full bg-p4a-neutral-surface" data-bar="">
            <span className="block h-1.5 rounded-full bg-p4a-deepblue" style={{ width: `${(barShare(p.attempts, largest) * 100).toFixed(1)}%` }} />
          </span>
        ) : null}
      </td>
      <td className={td}>{fmtAttempts(p.avgAttempts, locale)}</td>
      <td className={td}>{fmtShare(firstReachShare(p), locale)}</td>
      <td className={td}>{n(p.openNeverAttempted)}</td>
    </>
  );
  return (
    <div className="overflow-x-auto" data-testid="attempts-agents-scroll" role="region" aria-label={t.title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="attempts-agents-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={`${th} w-56`}><HintLabel label={t.person}>{hint(t.person, hints.atAgentName!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.deals}>{hint(a.deals, hints.atAgentDeals!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.attempted}>{hint(a.attempted, hints.atAgentAttempted!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.attemptsCol}>{hint(a.attemptsCol, hints.atAgentAttempts!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.perDeal}>{hint(a.perDeal, hints.atAgentAvg!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.firstReach}>{hint(a.firstReach, hints.atAgentFirst!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={a.openNever}>{hint(a.openNever, hints.atAgentOpenNever!)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => (
            <tr key={p.userId ?? `not-linked`} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50"
              data-testid={p.kind === "notLinked" ? "attempts-agent-not-linked" : "attempts-agent-row"}>
              <td className="h-10 px-2 font-semibold">{nameOf(p)}</td>
              {cells(p, true)}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body" data-testid="attempts-agents-total">
            <td className="h-10 px-2 font-semibold">{copy.reports.total}</td>
            {cells(total, false)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
