"use client";

/**
 * Email per agent's table (addition 0008t; brief N19-A part 1): one row per person, sorted by name and never
 * ranked (README Decision log, 7 and 14 October 2026, and 18 October 2026: Yordi agreed to the per-person email
 * figures), the actions of owner ids without a person last as one row with how many owner ids that is, then the
 * total. Every count carries an inline bar scaled to its column's largest value, in the style's series
 * (docs/style/Pulse4all-Style.md 7.7): sent Deep Blue, first replies Leaf Green, closed Light Blue, never with
 * text on it (7.8). A row opens with Enter on its name or a click anywhere on it and shows that person's sends
 * per hour of the day as 24 small columns; Up and Down move between the people. Rows follow 7.6. Staff names
 * only: no owner id, no address, no subject.
 */
import { Fragment, useRef, useState, type KeyboardEvent } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { EmailPerson } from "@/lib/data";
import { withinShare } from "@/lib/email";
import { barShare, fmtCount, fmtShare, fmtTalk } from "@/lib/reports";
import { HeaderHint } from "./HeaderHint";

type Bar = "sent" | "replies" | "threadsClosed";
const BAR_CLASS: Record<Bar, string> = { sent: "bg-p4a-deepblue", replies: "bg-p4a-green", threadsClosed: "bg-p4a-lightblue" };

const keyOf = (p: Pick<EmailPerson, "kind" | "userId">) => (p.kind === "person" ? `person:${p.userId}` : p.kind);

export function EmailPerAgentTable({ rows, total, hints, copy, locale }: {
  rows: EmailPerson[];
  total: EmailPerson;
  /** The hint texts by key, the tenant's values filled in */
  hints: Record<string, string>;
  copy: Copy;
  locale: Locale;
}) {
  const t = copy.emailPerAgent;
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const buttons = useRef<Map<string, HTMLButtonElement>>(new Map());
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const largest: Record<Bar, number> = {
    sent: Math.max(0, ...rows.map((r) => r.sent)), replies: Math.max(0, ...rows.map((r) => r.replies)),
    threadsClosed: Math.max(0, ...rows.map((r) => r.threadsClosed)),
  };
  const th = "h-10 px-1.5 py-1 align-bottom font-semibold";
  const td = "h-10 whitespace-nowrap px-1.5 py-1.5";
  const nameCell = "h-10 w-48 min-w-36 px-1.5 py-1.5 font-semibold";
  const nameOf = (p: EmailPerson) => (p.kind === "person" ? p.name ?? ""
    : p.unlinkedOwners === 1 ? t.notLinkedOne : p.unlinkedOwners ? t.notLinkedMany.replace("{n}", n(p.unlinkedOwners)) : t.notLinkedNone);
  const keys = rows.map(keyOf);

  function toggle(key: string) {
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function move(e: KeyboardEvent<HTMLButtonElement>, key: string) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const next = keys[keys.indexOf(key) + (e.key === "ArrowDown" ? 1 : -1)];
    if (next) buttons.current.get(next)?.focus();
  }

  const count = (p: EmailPerson, c: Bar, bars: boolean) => (
    <td className={`${td} tabular text-right ${p.kind === "total" ? "font-semibold" : ""}`}>
      <span className="block">{n(p[c])}</span>
      {bars ? (
        <span aria-hidden="true" className="ml-auto mt-1 block h-1.5 w-12 overflow-hidden rounded-full bg-p4a-neutral-surface" data-bar="">
          <span className={`block h-1.5 rounded-full ${BAR_CLASS[c]}`} style={{ width: `${(barShare(p[c], largest[c]) * 100).toFixed(1)}%` }} />
        </span>
      ) : null}
    </td>
  );
  const figures = (p: EmailPerson, bars: boolean) => (
    <>
      {count(p, "sent", bars)}
      {count(p, "replies", bars)}
      <td className={`${td} tabular text-right`}>{fmtTalk(p.replyMedianBusinessSeconds, locale)}</td>
      <td className={`${td} tabular text-right`}>{fmtShare(withinShare(p), locale)}</td>
      {count(p, "threadsClosed", bars)}
    </>
  );

  return (
    <div className="overflow-x-auto" data-testid="email-agents-scroll" role="region" aria-label={t.title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="email-agents-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={`${th} w-48`}>{t.agent}{hint(t.agent, hints.emailAgentName!)}</th>
            <th className={`${th} text-right`}>{t.sent}{hint(t.sent, hints.emailAgentSent!)}</th>
            <th className={`${th} text-right`}>{t.replies}{hint(t.replies, hints.emailAgentReplies!)}</th>
            <th className={`${th} text-right`}>{t.medianReply}{hint(t.medianReply, hints.emailAgentMedian!)}</th>
            <th className={`${th} text-right`}>{t.within}{hint(t.within, hints.emailAgentWithin!)}</th>
            <th className={`${th} text-right`}>{t.closed}{hint(t.closed, hints.emailAgentClosed!)}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => {
            const key = keyOf(p);
            const expanded = open.has(key);
            const name = nameOf(p);
            const most = Math.max(0, ...p.sentByHour);
            return (
              <Fragment key={key}>
                <tr className="cursor-pointer border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50"
                  data-testid={p.kind === "notLinked" ? "email-agent-not-linked" : "email-agent-row"} onClick={() => toggle(key)}>
                  <td className={nameCell}>
                    <button
                      type="button"
                      ref={(el) => { if (el) buttons.current.set(key, el); else buttons.current.delete(key); }}
                      aria-expanded={expanded}
                      aria-controls={`hours-${key}`}
                      aria-label={(expanded ? t.collapse : t.expand).replace("{name}", name)}
                      onClick={(e) => { e.stopPropagation(); toggle(key); }}
                      onKeyDown={(e) => move(e, key)}
                      className="inline-flex items-start gap-2 rounded-button text-left font-semibold text-p4a-body hover:text-p4a-deepblue"
                      data-testid="email-agent-toggle"
                    >
                      <svg aria-hidden="true" viewBox="0 0 16 16" className={`mt-1 h-3 w-3 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M6 3l5 5-5 5" />
                      </svg>
                      <span>{name}</span>
                    </button>
                  </td>
                  {figures(p, true)}
                </tr>
                {expanded ? (
                  <tr id={`hours-${key}`} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite" data-testid="email-agent-hours">
                    <td colSpan={6} className={`${td} py-3`}>
                      <p className="mb-2 text-small">
                        <span className="font-semibold text-p4a-heading">{t.hours}</span>
                        <span className="ml-2 text-p4a-muted">{t.hoursOf.replace("{n}", n(p.sent))}</span>
                      </p>
                      {p.sent === 0 ? <p className="text-small text-p4a-muted">{t.hoursEmpty}</p> : (
                        <ol className="grid max-w-3xl grid-cols-24 items-end gap-1" aria-label={`${t.hours}: ${name}`}>
                          {p.sentByHour.map((v, hour) => (
                            <li key={hour} className="flex flex-col items-center gap-1" title={`${t.hourLabel.replace("{hour}", String(hour).padStart(2, "0"))}: ${n(v)}`}>
                              <span className="flex h-16 w-full items-end rounded-sm bg-p4a-neutral-surface">
                                <span className="block w-full rounded-sm bg-p4a-deepblue" style={{ height: `${(barShare(v, most) * 100).toFixed(1)}%` }} />
                              </span>
                              <span className="tabular text-caption text-p4a-grey">{hour % 3 === 0 ? String(hour).padStart(2, "0") : ""}</span>
                            </li>
                          ))}
                        </ol>
                      )}
                    </td>
                  </tr>
                ) : null}
              </Fragment>
            );
          })}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body" data-testid="email-agents-total">
            <td className={nameCell}>{copy.reports.total}</td>
            {figures(total, false)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
