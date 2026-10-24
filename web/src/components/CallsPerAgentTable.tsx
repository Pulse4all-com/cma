"use client";

/**
 * Calls per agent's table (addition 0008j, brief B16; Aircall's User Activity view): one row per person,
 * sorted by name and never ranked (README Decision log, 7 and 14 October 2026), the calls of telephony
 * users without a person last as one row with their count (a link to Data quality for those who may open
 * it), and the total. The total talk time in and out is no column since 19 October 2026 (Martin): the averages
 * stay. Every figure column carries an inline bar scaled to the column's largest value, in
 * the style's series (docs/style/Pulse4all-Style.md 7.7): inbound Deep Blue, outbound Leaf Green,
 * conversations Light Blue, never with text on it (7.8). A row opens with Enter on its name or a click
 * anywhere on it and shows that person's conversations per counted tag as small horizontal bars with
 * count and share, then the untagged ones; Up and Down move between the people. Rows follow 7.6 (zebra
 * rows, a hover row, at least 40px). Staff names only: no telephony user id, no number, no call id.
 */
import Link from "next/link";
import { Fragment, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { CallsPerson, CallsPersonTag } from "@/lib/data";
import {
  barShare, columnMaxima, fmtCount, fmtShare, fmtTalk, PER_AGENT_BAR_CLASS, personKey, personSplit, TAG_CLASS, type PerAgentBar,
} from "@/lib/reports";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";

type Column = { key: PerAgentBar; label: string; hint: string; talk?: boolean };

export function CallsPerAgentTable({ rows, total, tags, copy, locale, threshold, dataQuality }: {
  rows: CallsPerson[];
  total: CallsPerson;
  tags: CallsPersonTag[];
  copy: Copy;
  locale: Locale;
  /** telephony.connected_min_seconds, for the hints */
  threshold: number;
  /** The viewer may open Data quality (reports.view or tenant.configure) */
  dataQuality: boolean;
}) {
  const t = copy.callsPerAgent;
  const h = copy.hints;
  const [open, setOpen] = useState<Set<string>>(() => new Set());
  const buttons = useRef<Map<string, HTMLButtonElement>>(new Map());
  const n = (x: number) => fmtCount(x, locale);
  const fill = (text: string) => text.replaceAll("{threshold}", n(threshold));
  const hint = (label: string, text: string) => <HeaderHint label={h.about.replace("{label}", label)} text={fill(text)} />;
  const columns: Column[] = [
    { key: "answeredInbound", label: t.answered, hint: h.agentAnswered },
    { key: "inboundTalkAvgSeconds", label: t.inboundAvg, hint: h.agentInboundAvg, talk: true },
    { key: "outboundCalls", label: t.outbound, hint: h.agentOutbound },
    { key: "connected", label: t.connected, hint: h.agentConnected },
    { key: "outboundTalkAvgSeconds", label: t.outboundAvg, hint: h.agentOutboundAvg, talk: true },
    { key: "untagged", label: t.untagged, hint: h.agentUntagged },
  ];
  const maxima = columnMaxima(rows);
  const value = (p: CallsPerson, c: Column) => (c.talk ? fmtTalk(p[c.key], locale) : n(p[c.key] ?? 0));
  // headers may wrap onto two lines, so the eight columns fit their card at 1280 px
  const th = "h-10 px-1.5 py-1 align-bottom font-semibold";
  const td = "h-10 whitespace-nowrap px-1.5 py-1.5";
  // the name may wrap, so a long name or the not-linked row never widens the table past its card
  const nameCell = "h-10 w-44 min-w-36 px-1.5 py-1.5 font-semibold";
  const nameOf = (p: CallsPerson) => (p.kind === "person" ? p.name ?? "" : p.unlinkedUsers === 1 ? t.notLinkedOne : t.notLinkedMany.replace("{n}", n(p.unlinkedUsers ?? 0)));
  const keys = rows.map(personKey);

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
    const i = keys.indexOf(key) + (e.key === "ArrowDown" ? 1 : -1);
    const next = keys[i];
    if (next) buttons.current.get(next)?.focus();
  }

  // the figure, with its bar under it against the column's largest (the total row has none)
  function figures(p: CallsPerson, bars: boolean): ReactNode {
    return columns.map((c) => (
      <td key={c.key} className={`${td} tabular text-right ${p.kind === "total" ? "font-semibold" : ""}`}>
        <span className="block">{value(p, c)}</span>
        {bars ? (
          <span aria-hidden="true" className="ml-auto mt-1 block h-1.5 w-12 overflow-hidden rounded-full bg-p4a-neutral-surface" data-bar="">
            <span className={`block h-1.5 rounded-full ${PER_AGENT_BAR_CLASS[c.key]}`} style={{ width: `${(barShare(p[c.key], maxima[c.key]) * 100).toFixed(1)}%` }} />
          </span>
        ) : null}
      </td>
    ));
  }
  const times = (p: CallsPerson) => (p.firstCallTime ? `${p.firstCallTime}–${p.lastCallTime}` : "–");

  return (
    <div className="overflow-x-auto" data-testid="agents-scroll" role="region" aria-label={t.title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="agents-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={`${th} w-44`}><HintLabel label={t.agent}>{hint(t.agent, h.agentName)}</HintLabel></th>
            {columns.map((c) => <th key={c.key} className={`${th} text-right`}><HintLabel label={c.label}>{hint(c.label, c.hint)}</HintLabel></th>)}
            <th className={`${th} text-right`}><HintLabel label={t.firstLast}>{hint(t.firstLast, h.agentFirstLast)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((p) => {
            const key = personKey(p);
            const expanded = open.has(key);
            const name = nameOf(p);
            const split = expanded ? personSplit(tags, p) : [];
            return (
              <Fragment key={key}>
                <tr className="cursor-pointer border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50"
                  data-testid={p.kind === "notLinked" ? "agent-not-linked" : "agent-row"} onClick={(e) => {
                    // a click on the row opens it; the Data quality link keeps its own click
                    if ((e.target as HTMLElement).closest("a")) return;
                    toggle(key);
                  }}>
                  <td className={nameCell}>
                    <button
                      type="button"
                      ref={(el) => { if (el) buttons.current.set(key, el); else buttons.current.delete(key); }}
                      aria-expanded={expanded}
                      aria-controls={`split-${key}`}
                      aria-label={(expanded ? t.collapse : t.expand).replace("{name}", name)}
                      onClick={(e) => { e.stopPropagation(); toggle(key); }}
                      onKeyDown={(e) => move(e, key)}
                      className="inline-flex items-start gap-2 rounded-button text-left font-semibold text-p4a-body hover:text-p4a-deepblue"
                      data-testid="agent-toggle"
                    >
                      <svg aria-hidden="true" viewBox="0 0 16 16" className={`mt-1 h-3 w-3 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                        <path d="M6 3l5 5-5 5" />
                      </svg>
                      <span>{name}</span>
                    </button>
                    {p.kind === "notLinked" ? (
                      dataQuality
                        ? <Link href="/reports/data-quality" className="mt-0.5 block pl-5 text-caption font-normal text-p4a-deepblue hover:underline" data-testid="not-linked-link">{t.notLinkedLink}</Link>
                        : <span className="mt-0.5 block pl-5 text-caption font-normal text-p4a-muted">{t.notLinkedNoAccess}</span>
                    ) : null}
                  </td>
                  {figures(p, true)}
                  <td className={`${td} tabular text-right`}>{times(p)}</td>
                </tr>
                {expanded ? (
                  <tr id={`split-${key}`} className="border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite" data-testid="agent-split">
                    <td colSpan={columns.length + 2} className={`${td} py-3`}>
                      <p className="mb-2 text-small">
                        <span className="font-semibold text-p4a-heading">{t.split}</span>
                        <span className="ml-2 text-p4a-muted">{t.splitOf.replace("{n}", n(p.conversations))}</span>
                      </p>
                      {p.conversations === 0 ? <p className="text-small text-p4a-muted">{t.splitEmpty}</p> : (
                        <ul className="flex max-w-3xl flex-col gap-1.5" aria-label={`${t.split}: ${name}`}>
                          {split.map((s) => (
                            <li key={s.key} className="grid grid-cols-[14rem_1fr_8rem] items-center gap-4 text-small" title={`${s.name}: ${n(s.count)}`}>
                              <span className="truncate">{s.name}</span>
                              <span className="h-2 rounded-full bg-p4a-neutral-surface">
                                <span className={`block h-2 rounded-full ${TAG_CLASS}`} style={{ width: `${(s.length * 100).toFixed(1)}%` }} />
                              </span>
                              <span className="tabular text-right text-p4a-muted">{n(s.count)} · {fmtShare(s.share, locale)}</span>
                            </li>
                          ))}
                        </ul>
                      )}
                    </td>
                  </tr>
                ) : null}
              </Fragment>
            );
          })}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body" data-testid="agents-total">
            <td className={nameCell}>{copy.reports.total}</td>
            {figures(total, false)}
            <td className={`${td} tabular text-right font-semibold`}>{times(total)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
