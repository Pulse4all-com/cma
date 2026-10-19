/**
 * Building blocks of Reports → Email (addition 0008t; brief N19-A part 1): the grouping switch (G), the date
 * line, the received messages per date as columns with one stacked part per inbox or mailbox, the sends of
 * agents and automations as columns, the figures per inbox, mailbox, category and market as tables, and the two
 * lists of what waits now (conversations waiting for a reply, lead deals not responding). Server components,
 * plain SVG and CSS, no chart library; the figures come from the data layer and lib/email arranges them.
 * Colours per docs/style/Pulse4all-Style.md 7.7: the series in the style's order (Deep Blue, Leaf Green, Light
 * Blue, Denim, Soft Rose, Inkt), Other in Muted; agents Deep Blue, automations Leaf Green; no red, no donut;
 * every mark carries its label in a title. Tables follow 7.6 and scroll sideways inside their card at 1280 px.
 * Ids, codes, counts and times only: no subject, no address, no name of a customer.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { EmailGroup, EmailNotRespondingRow, EmailRow, EmailSeriesRow, EmailWaitingRow } from "@/lib/data";
import {
  AGENT_SEND_CLASS, AUTOMATED_CLASS, EMAIL_GROUPS, nextEmailGroup, OTHER_SERIES_CLASS, OTHER_SERIES_FILL, SERIES_CLASSES, SERIES_FILLS, seriesColumns,
  withinShare,
} from "@/lib/email";
import { countAxis, fmtCount, fmtShare, fmtTalk, weekNumber } from "@/lib/reports";
import { addDays, dateKeyInZone, fmtDate, fmtDateTimeShort, startOfWeek } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { Keycap } from "./primitives";

/** Day or week as links on the Email report; G moves to the other */
export function EmailGroupSwitch({ group, query, copy }: { group: EmailGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.email;
  const labels: Record<EmailGroup, string> = { day: t.day, week: t.week };
  const next = nextEmailGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {EMAIL_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/email", query: { ...query, group: g } }}
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

/** The page's date line: the period, then the active filters in words */
export function EmailDateLine({ from, to, market, inbox, account, inboxes, accounts, copy, locale }: {
  from: string; to: string; market: string | null; inbox: string | null; account: string | null;
  inboxes: { key: string; name: string }[]; accounts: { key: string; name: string }[]; copy: Copy; locale: Locale;
}) {
  const t = copy.email;
  const nameOf = (list: { key: string; name: string }[], key: string) => list.find((x) => x.key === key)?.name ?? key.split(":").slice(1).join(":");
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(market ? [t.activeMarket.replace("{market}", market === "unknown" ? copy.reports.unknownMarket : market)] : []),
    ...(inbox ? [t.activeInbox.replace("{inbox}", nameOf(inboxes, inbox))] : []),
    ...(account ? [t.activeAccount.replace("{account}", nameOf(accounts, account))] : []),
  ];
  return <p className="text-caption text-p4a-grey" data-testid="email-date-line">{parts.join(" · ")}</p>;
}

/** A date or week label for the axis */
function dateLabel(key: string, group: EmailGroup, copy: Copy, locale: Locale, short: boolean): string {
  return group === "week" ? copy.email.weekLabel.replace("{week}", String(weekNumber(key))) : fmtDate(key, locale, short ? "short" : "compact");
}

export type Column = { key: string; parts: { key: string; label: string; value: number; fill: string }[] };

/** Columns over the dates or weeks, each stacked from its parts; gridlines Border Grey, axis labels 12 units Footnote Grey (7.7). First orders (0008u) uses them too */
export function StackedColumns({ columns, group, label, testId, copy, locale }: {
  columns: Column[]; group: EmailGroup; label: string; testId: string; copy: Copy; locale: Locale;
}) {
  const n = (x: number) => fmtCount(x, locale);
  const W = 960;
  const H = 240;
  const m = { l: 44, r: 8, t: 12, b: 30 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const totals = columns.map((c) => c.parts.reduce((a, p) => a + p.value, 0));
  const axis = countAxis(Math.max(0, ...totals));
  const y = (v: number) => m.t + plotH - (v / axis.top) * plotH;
  const band = plotW / Math.max(1, columns.length);
  const barW = Math.min(44, band * 0.6);
  const labelEvery = Math.ceil(columns.length / 12);
  const ticks: number[] = [];
  for (let v = 0; v <= axis.top; v += axis.step) ticks.push(v);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={label} data-testid={testId}>
      {ticks.map((v) => (
        <g key={v}>
          <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
          <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{n(v)}</text>
        </g>
      ))}
      {columns.map((c, i) => {
        const x = m.l + i * band + (band - barW) / 2;
        let base = 0;
        const title = `${dateLabel(c.key, group, copy, locale, false)}: ${c.parts.filter((p) => p.value > 0).map((p) => `${p.label} ${n(p.value)}`).join(", ") || n(0)}`;
        return (
          <g key={c.key}>
            <title>{title}</title>
            {c.parts.map((p) => {
              if (p.value <= 0) return null;
              const top = base + p.value;
              const rect = <rect key={p.key} x={x} y={y(top)} width={barW} height={Math.max(0, y(base) - y(top))} className={p.fill} />;
              base = top;
              return rect;
            })}
            {i % labelEvery === 0 ? (
              <text x={m.l + i * band + band / 2} y={H - 10} textAnchor="middle" fontSize={12} className="fill-p4a-grey">
                {dateLabel(c.key, group, copy, locale, columns.length > 7)}
              </text>
            ) : null}
          </g>
        );
      })}
    </svg>
  );
}

export function Legend({ items, label, testId }: { items: { key: string; label: string; className: string }[]; label: string; testId: string }) {
  return (
    <ul className="mb-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-caption text-p4a-grey" aria-label={label} data-testid={testId}>
      {items.map((x) => (
        <li key={x.key} className="flex items-center gap-2"><span aria-hidden="true" className={`inline-block h-2.5 w-2.5 rounded-full ${x.className}`} />{x.label}</li>
      ))}
    </ul>
  );
}

/** Received per date (or week) as columns, one stacked part per inbox or mailbox in the style's order, the rest as Other */
export function ReceivedColumns({ rows, group, from, to, last, split, copy, locale }: {
  rows: EmailSeriesRow[]; group: EmailGroup; from: string; to: string; last: string; split: "inbox" | "account"; copy: Copy; locale: Locale;
}) {
  const t = copy.email;
  const { keys, series, values } = seriesColumns(rows, group, from, to, last);
  const nameOf = (s: { key: string; label: string | null; index: number | null }) =>
    s.index === null ? t.other : s.key === "none" ? (split === "inbox" ? t.noInbox : t.noAccount) : s.label ?? s.key.split(":").slice(1).join(":");
  const classOf = (s: { index: number | null }) => (s.index === null ? OTHER_SERIES_CLASS : SERIES_CLASSES[s.index]!);
  const fillOf = (s: { index: number | null }) => (s.index === null ? OTHER_SERIES_FILL : SERIES_FILLS[s.index]!);
  const columns: Column[] = keys.map((k) => ({
    key: k, parts: series.map((s) => ({ key: s.key, label: nameOf(s), value: values.get(`${k}|${s.key}`) ?? 0, fill: fillOf(s) })),
  }));
  return (
    <>
      <Legend items={series.map((s) => ({ key: s.key, label: nameOf(s), className: classOf(s) }))} label={t.legend} testId={`email-legend-${split}`} />
      <StackedColumns columns={columns} group={group} label={split === "inbox" ? t.receivedInbox : t.receivedAccount} testId={`email-received-${split}`} copy={copy} locale={locale} />
    </>
  );
}

/** Sent per date (or week): agents Deep Blue, automations Leaf Green, stacked */
export function SentColumns({ rows, group, from, to, last, copy, locale }: {
  rows: EmailRow[]; group: EmailGroup; from: string; to: string; last: string; copy: Copy; locale: Locale;
}) {
  const t = copy.email;
  const end = to < last ? to : last;
  const keys: string[] = [];
  for (let d = group === "day" ? from : startOfWeek(from); d <= end; d = addDays(d, group === "day" ? 1 : 7)) keys.push(d);
  const known = new Map(rows.map((r) => [r.groupKey, r]));
  const columns: Column[] = keys.map((k) => ({
    key: k, parts: [
      { key: "agent", label: t.legendAgent, value: known.get(k)?.sentAgent ?? 0, fill: "fill-p4a-deepblue" },
      { key: "automated", label: t.legendAutomated, value: known.get(k)?.sentAutomated ?? 0, fill: "fill-p4a-green" },
    ],
  }));
  return (
    <>
      <Legend items={[{ key: "agent", label: t.legendAgent, className: AGENT_SEND_CLASS }, { key: "automated", label: t.legendAutomated, className: AUTOMATED_CLASS }]}
        label={t.legend} testId="email-legend-sent" />
      <StackedColumns columns={columns} group={group} label={t.sentChart} testId="email-sent-chart" copy={copy} locale={locale} />
    </>
  );
}

const th = "h-10 whitespace-nowrap px-2 py-1 font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** The label of a dimension's group: an inbox or mailbox by its name, a category by its code, a market by its code ('none' and unknown in words) */
export function emailGroupLabel(r: Pick<EmailRow, "groupKey" | "groupLabel">, dimension: "inbox" | "account" | "category" | "market", copy: Copy): string {
  const t = copy.email;
  if (r.groupKey === "none") return dimension === "inbox" ? t.noInbox : dimension === "account" ? t.noAccount : t.noCategory;
  if (dimension === "market") return r.groupKey === "unknown" ? copy.reports.unknownMarket : r.groupKey;
  return r.groupLabel ?? r.groupKey.split(":").slice(1).join(":");
}

type FigureColumn = "received" | "loggedReplies" | "sentAgent" | "sentAutomated" | "threadsOpened" | "replied" | "medianReply" | "medianElapsed" | "within"
  | "noHours" | "threadsClosed" | "medianClose";

/**
 * The figures per inbox, mailbox, category or market: the columns asked for, each with its hint ({hours} and
 * {target} filled in by the page); a group without email reads 0, a median without replies a dash
 */
export function EmailFiguresTable({ rows, dimension, columns, hints, title, testId, copy, locale }: {
  rows: EmailRow[]; dimension: "inbox" | "account" | "category" | "market"; columns: FigureColumn[];
  /** The hint texts by key, values filled in */
  hints: Record<string, string>;
  title: string; testId: string; copy: Copy; locale: Locale;
}) {
  const t = copy.email;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const head: Record<FigureColumn, [string, string]> = {
    received: [t.received, hints.emailReceivedCol!], loggedReplies: [t.loggedReplies, hints.emailLoggedCol!], sentAgent: [t.sent, hints.emailSentCol!],
    sentAutomated: [t.automated, hints.emailAutomatedCol!], threadsOpened: [t.opened, hints.emailOpenedCol!], replied: [t.replied, hints.emailRepliedCol!],
    medianReply: [t.medianReply, hints.emailMedianReplyCol!], medianElapsed: [t.medianElapsed, hints.emailElapsedCol!], within: [t.within, hints.emailWithinCol!],
    noHours: [t.noHours, hints.emailNoHoursCol!], threadsClosed: [t.closed, hints.emailClosedCol!], medianClose: [t.medianClose, hints.emailMedianCloseCol!],
  };
  const value = (r: EmailRow, c: FigureColumn): string => {
    switch (c) {
      case "medianReply": return fmtTalk(r.replyMedianBusinessSeconds, locale);
      case "medianElapsed": return fmtTalk(r.replyMedianSeconds, locale);
      case "within": return fmtShare(withinShare(r), locale);
      case "medianClose": return fmtTalk(r.closeMedianBusinessSeconds, locale);
      default: return n(r[c]);
    }
  };
  const firstLabel = { inbox: t.inbox, account: t.account, category: t.category, market: t.market }[dimension];
  const firstHint = { inbox: hints.emailInbox!, account: hints.emailAccount!, category: hints.emailCategory!, market: hints.emailMarket! }[dimension];
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={title} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={firstLabel}>{hint(firstLabel, firstHint)}</HintLabel></th>
            {columns.map((c) => <th key={c} className={`${th} text-right`}><HintLabel label={head[c][0]}>{hint(head[c][0], head[c][1])}</HintLabel></th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.groupKey} className={row}>
              <td className="h-10 max-w-64 truncate px-2 font-semibold" title={emailGroupLabel(r, dimension, copy)}>{emailGroupLabel(r, dimension, copy)}</td>
              {columns.map((c) => <td key={c} className={td}>{value(r, c)}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Seconds as the tables show them: elapsed, or "No business hours" for a business figure of an unknown market */
function businessOrNone(seconds: number | null, copy: Copy, locale: Locale): string {
  return seconds === null ? copy.email.noBusinessHours : fmtTalk(seconds, locale);
}

/** The conversations waiting now: ids, ages and links only, longest waiting first */
export function WaitingTable({ rows, hints, copy, locale, timeZone }: { rows: EmailWaitingRow[]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string }) {
  const t = copy.email;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const market = (m: string) => (m === "unknown" ? copy.reports.unknownMarket : m);
  return (
    <div className="overflow-x-auto" data-testid="email-waiting-scroll" role="region" aria-label={t.waitingTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="email-waiting">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.conversation}>{hint(t.conversation, hints.emailWaitConversation!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.inbox}>{hint(t.inbox, hints.emailWaitInbox!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.account}>{hint(t.account, hints.emailWaitAccount!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.market}>{hint(t.market, hints.emailWaitMarket!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.waitingSince}>{hint(t.waitingSince, hints.emailWaitingSince!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.waited}>{hint(t.waited, hints.emailWaited!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.waitedElapsed}>{hint(t.waitedElapsed, hints.emailWaitedElapsed!)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.connectionId}:${r.threadId}`} className={row}>
              <td className="h-10 whitespace-nowrap px-2">
                {r.recordUrl ? <a href={r.recordUrl} target="_blank" rel="noopener noreferrer" className="text-p4a-deepblue underline">{r.threadId}</a> : r.threadId}
              </td>
              <td className="h-10 max-w-48 truncate px-2">{r.inboxName ?? "–"}</td>
              <td className="h-10 max-w-48 truncate px-2">{r.accountName ?? "–"}</td>
              <td className="h-10 whitespace-nowrap px-2">{market(r.market)}</td>
              <td className={td}>{fmtDateTimeShort(r.waitingSince, timeZone, locale)}</td>
              <td className={td}>{businessOrNone(r.waitedBusinessSeconds, copy, locale)}</td>
              <td className={td}>{fmtTalk(r.waitedSeconds, locale)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The open lead deals not responding: ids, ages and links only, the oldest email first */
export function NotRespondingTable({ rows, hints, copy, locale, timeZone }: { rows: EmailNotRespondingRow[]; hints: Record<string, string>; copy: Copy; locale: Locale; timeZone: string }) {
  const t = copy.email;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  const market = (m: string) => (m === "unknown" ? copy.reports.unknownMarket : m);
  return (
    <div className="overflow-x-auto" data-testid="email-not-responding-scroll" role="region" aria-label={t.notRespondingTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="email-not-responding">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.deal}>{hint(t.deal, hints.emailNrDeal!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.pipeline}>{hint(t.pipeline, hints.emailNrPipeline!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.market}>{hint(t.market, hints.emailNrMarket!)}</HintLabel></th>
            <th className={th}><HintLabel label={t.owner}>{hint(t.owner, hints.emailNrOwner!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.lastEmail}>{hint(t.lastEmail, hints.emailNrLastEmail!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.daysSince}>{hint(t.daysSince, hints.emailNrDays!)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.connectionId}:${r.dealId}`} className={row}>
              <td className="h-10 whitespace-nowrap px-2">
                {r.recordUrl ? <a href={r.recordUrl} target="_blank" rel="noopener noreferrer" className="text-p4a-deepblue underline">{r.dealId}</a> : r.dealId}
              </td>
              <td className="h-10 max-w-48 truncate px-2">{r.pipelineLabel}</td>
              <td className="h-10 whitespace-nowrap px-2">{market(r.market)}</td>
              <td className="h-10 max-w-48 truncate px-2">{r.ownerName ?? <span className="text-p4a-muted">{t.notLinked}</span>}</td>
              <td className={td}>{fmtDate(dateKeyInZone(r.lastEmailAt, timeZone), locale, "short")}</td>
              <td className={td}>{fmtCount(r.daysSince, locale)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
