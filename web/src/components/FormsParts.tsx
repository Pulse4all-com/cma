/**
 * Building blocks of Reports → Forms (addition 0008p, brief B17d): the grouping switch (G), the date line,
 * the submissions per day or week as columns, the table of forms per market with the previous period and
 * the resolution split, the totals per category and per market, how the contacts were found, and the kept
 * answers. Server components, plain SVG and CSS, no chart library; the figures come from the data layer
 * and lib/reports arranges them. Colours per docs/style/Pulse4all-Style.md 7.7: the submissions Deep Blue,
 * the resolution's bars in the series order with their labels beside them (7.8: no text on a Light Blue or
 * Soft Rose bar); a volume's change against the previous period is neither good nor bad, so it is Muted
 * with an arrow (as Calls). Every header explains itself in a hint. Form names, codes and counts only: no
 * submission, no contact, no email address, no free-text answer.
 */
import Link from "next/link";
import type { Copy, Locale } from "@/lib/copy";
import type { FormAnswerRow, FormCategory, FormsFilter, FormsGroup } from "@/lib/data";
import {
  answerGroups, callsChange, countAxis, FORMS_GROUPS, fmtCount, fmtShare, type FormsLine, formsSum, formsTableGroups, nextFormsGroup, weekNumber,
} from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { Keycap } from "./primitives";

const th = "h-10 whitespace-nowrap px-2 py-1 font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

/** A grouped table's body row: zebra over every body row of the table (7.6), the groups shown by weight and indent, never by colour */
function zebra(index: number): string {
  return `border-b border-p4a-border hover:bg-p4a-bgblue/50 ${index % 2 === 1 ? "bg-p4a-offwhite" : "bg-white"}`;
}

function hintOf(copy: Copy, label: string, text: string) {
  return <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
}

/** Day or week as links on the Forms report; G moves to the next one */
export function FormsGroupSwitch({ group, query, copy }: { group: FormsGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.forms;
  const labels: Record<FormsGroup, string> = { day: t.day, week: t.week };
  const next = nextFormsGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {FORMS_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/forms", query: { ...query, group: g } }}
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

/** A category code in words: the tenant's name, the code when the catalog lacks it, "No category" for none */
export function categoryLabel(code: string | null, categories: readonly FormCategory[], copy: Copy): string {
  if (code === null || code === "none") return copy.forms.noCategory;
  return categories.find((c) => c.code === code)?.name ?? code;
}

/** A market code in words: the code, or "Unknown market" */
export function marketLabel(market: string, copy: Copy): string {
  return market === "unknown" ? copy.reports.unknownMarket : market;
}

/** The page's date line: the period, then the active filters in words (market, category, form by its name) */
export function FormsDateLine({ from, to, filter, categories, forms, copy, locale }: {
  from: string; to: string; filter: FormsFilter; categories: readonly FormCategory[]; forms: readonly { key: string; name: string }[];
  copy: Copy; locale: Locale;
}) {
  const t = copy.forms;
  const parts = [
    `${fmtDate(from, locale)}${from !== to ? ` – ${fmtDate(to, locale)}` : ""}`,
    ...(filter.market ? [t.activeMarket.replace("{market}", marketLabel(filter.market, copy))] : []),
    ...(filter.category ? [t.activeCategory.replace("{category}", categoryLabel(filter.category, categories, copy))] : []),
    ...(filter.form ? [t.activeForm.replace("{form}", forms.find((f) => f.key === filter.form)?.name ?? filter.form.split(":").slice(1).join(":"))] : []),
  ];
  return <p className="text-caption text-p4a-grey" data-testid="forms-date-line">{parts.join(" · ")}</p>;
}

/** A column's label: a date or a week number */
function seriesLabel(key: string, group: FormsGroup, copy: Copy, locale: Locale, short: boolean): string {
  return group === "day" ? fmtDate(key, locale, short ? "short" : "compact") : copy.forms.weekLabel.replace("{week}", String(weekNumber(key)));
}

/**
 * The submissions per day or week as Deep Blue columns, in a fixed viewBox that scales with the card;
 * gridlines Border Grey and axis labels 12 units Footnote Grey (7.7)
 */
export function FormsChart({ series, group, copy, locale }: { series: { key: string; submissions: number }[]; group: FormsGroup; copy: Copy; locale: Locale }) {
  const t = copy.forms;
  const n = (x: number) => fmtCount(x, locale);
  const W = 960;
  const H = 240;
  const m = { l: 44, r: 8, t: 12, b: 30 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const axis = countAxis(Math.max(0, ...series.map((s) => s.submissions)));
  const y = (count: number) => m.t + plotH - (count / axis.top) * plotH;
  const band = plotW / Math.max(1, series.length);
  const barW = Math.min(44, band * 0.6);
  const labelEvery = Math.ceil(series.length / 12);
  const ticks: number[] = [];
  for (let v = 0; v <= axis.top; v += axis.step) ticks.push(v);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={group === "day" ? t.chartDay : t.chartWeek} data-testid="forms-chart">
      {ticks.map((v) => (
        <g key={v}>
          <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
          <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{n(v)}</text>
        </g>
      ))}
      {series.map((s, i) => {
        const x = m.l + i * band + (band - barW) / 2;
        return (
          <g key={s.key}>
            <title>{`${seriesLabel(s.key, group, copy, locale, false)}: ${n(s.submissions)} ${t.submissions.toLowerCase()}`}</title>
            {s.submissions > 0 ? <rect x={x} y={y(s.submissions)} width={barW} height={Math.max(0, y(0) - y(s.submissions))} className="fill-p4a-deepblue" /> : null}
            {i % labelEvery === 0 ? (
              <text x={m.l + i * band + band / 2} y={H - 10} textAnchor="middle" fontSize={12} className="fill-p4a-grey">
                {seriesLabel(s.key, group, copy, locale, series.length > 7)}
              </text>
            ) : null}
          </g>
        );
      })}
    </svg>
  );
}

/** A figure's change against the previous period in a table cell: an arrow and the share, Muted; "No history" before the history starts */
function ChangeCell({ current, previous, previousFrom, historyStart, copy, locale }: {
  current: number; previous: number; previousFrom: string; historyStart: string | null; copy: Copy; locale: Locale;
}) {
  const t = copy.forms;
  const d = callsChange(current, previous, previousFrom, historyStart);
  const text = d.direction === "noHistory" ? t.changeNoHistory
    : d.direction === "same" ? t.changeSame
    : d.direction === "none" ? "–"
    : d.pct === null ? t.changeNew
    : (d.direction === "up" ? t.changeUp : t.changeDown).replace("{pct}", fmtShare(d.pct / 100, locale));
  return <td className={`${td} text-p4a-muted`} data-direction={d.direction}>{text}</td>;
}

interface PreviousOf { previousFrom: string; historyStart: string | null }

/**
 * The forms per market: each form on a row of its own with its category and its submissions over its
 * markets, then a row per market; the submissions, the previous period's, the change and the contacts found
 * with their share (the whole split is in the card below and in the file); the total in the foot. Scrolls
 * sideways inside its card where it is wider (1280 px)
 */
export function FormsTable({ lines, categories, prev, copy, locale }: {
  lines: FormsLine[]; categories: readonly FormCategory[]; prev: PreviousOf; copy: Copy; locale: Locale;
}) {
  const t = copy.forms;
  const h = copy.hints;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => hintOf(copy, label, text);
  const sum = formsSum(lines);
  const previous = lines.reduce((a, l) => a + l.previous, 0);
  const found = (l: { resolved: number; submissions: number }, bold = false) => (
    <td className={`${td} ${bold ? "font-semibold" : ""}`}>
      {n(l.resolved)} <span className="font-normal text-p4a-muted">· {fmtShare(l.submissions === 0 ? null : l.resolved / l.submissions, locale)}</span>
    </td>
  );
  let index = 0;
  return (
    <div className="overflow-x-auto" data-testid="forms-table-scroll" role="region" aria-label={t.tableTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="forms-table">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.formMarket}>{hint(t.formMarket, `${h.formsForm} ${h.formsMarket}`)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.submissions}>{hint(t.submissions, h.formsSubmissions)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.previous}>{hint(t.previous, h.formsPrevious)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.change}>{hint(t.change, h.formsChange)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.resolved}>{hint(t.resolved, h.formsResolved)}</HintLabel></th>
          </tr>
        </thead>
        {formsTableGroups(lines).map((g) => (
          <tbody key={g.formKey} data-form={g.formKey}>
            <tr className={zebra(index++)} data-form-total="">
              <td className="h-10 px-2">
                <span className="flex items-baseline gap-2">
                  <span className="block max-w-[22rem] truncate font-semibold" title={g.formName}>{g.formName}</span>
                  <span className="whitespace-nowrap text-caption text-p4a-muted">{categoryLabel(g.category, categories, copy)}</span>
                </span>
              </td>
              <td className={`${td} font-semibold`}>{n(g.total.submissions)}</td>
              <td className={`${td} font-semibold`}>{n(g.total.previous)}</td>
              <ChangeCell current={g.total.submissions} previous={g.total.previous} {...prev} copy={copy} locale={locale} />
              {found(g.total, true)}
            </tr>
            {g.markets.map((l) => (
              <tr key={l.market} className={zebra(index++)} data-market={l.market}>
                <td className="h-10 whitespace-nowrap py-1 pl-8 pr-2 text-small">{marketLabel(l.market, copy)}</td>
                <td className={td}>{n(l.submissions)}</td>
                <td className={td}>{n(l.previous)}</td>
                <ChangeCell current={l.submissions} previous={l.previous} {...prev} copy={copy} locale={locale} />
                {found(l)}
              </tr>
            ))}
          </tbody>
        ))}
        <tfoot>
          <tr className="text-p4a-body" data-testid="forms-table-total">
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{copy.reports.total}</td>
            <td className={`${td} font-semibold`}>{n(sum.submissions)}</td>
            <td className={`${td} font-semibold`}>{n(previous)}</td>
            <ChangeCell current={sum.submissions} previous={previous} {...prev} copy={copy} locale={locale} />
            {found(sum, true)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

/** Totals per category or per market: submissions, the previous period's and the change, the total in the foot */
export function FormsTotals({ title, label, labelHint, totalHint, rows, prev, testId, copy, locale }: {
  title: string; label: string; labelHint: string; totalHint: string; rows: { key: string; label: string; submissions: number; previous: number }[];
  prev: PreviousOf; testId: string; copy: Copy; locale: Locale;
}) {
  const t = copy.forms;
  const h = copy.hints;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (l: string, text: string) => hintOf(copy, l, text);
  const submissions = rows.reduce((a, r) => a + r.submissions, 0);
  const previous = rows.reduce((a, r) => a + r.previous, 0);
  return (
    <section aria-labelledby={`${testId}-title`}>
      <h3 id={`${testId}-title`} className="mb-3 text-body font-semibold text-p4a-heading">{title}</h3>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={label}>{hint(label, labelHint)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.submissions}>{hint(t.submissions, totalHint)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.previous}>{hint(t.previous, h.formsPrevious)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.change}>{hint(t.change, h.formsChange)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.key} className={row}>
              <td className="h-10 whitespace-nowrap px-2 font-semibold">{r.label}</td>
              <td className={td}>{n(r.submissions)}</td>
              <td className={td}>{n(r.previous)}</td>
              <ChangeCell current={r.submissions} previous={r.previous} {...prev} copy={copy} locale={locale} />
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="text-p4a-body">
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{copy.reports.total}</td>
            <td className={`${td} font-semibold`}>{n(submissions)}</td>
            <td className={`${td} font-semibold`}>{n(previous)}</td>
            <ChangeCell current={submissions} previous={previous} {...prev} copy={copy} locale={locale} />
          </tr>
        </tfoot>
      </table>
    </section>
  );
}

/** The resolution's bars in the series order (7.7); a label and the count beside each, never on it */
const RESOLUTION_CLASS = {
  resolved: "bg-p4a-deepblue", notFound: "bg-p4a-green", ambiguous: "bg-p4a-lightblue", noEmail: "bg-p4a-denim", pending: "bg-p4a-rose",
} as const;

/** How the contacts were found: one bar per outcome of the lookup, its count and its share of the submissions */
export function ResolutionBars({ lines, copy, locale }: { lines: FormsLine[]; copy: Copy; locale: Locale }) {
  const t = copy.forms;
  const h = copy.hints;
  const sum = formsSum(lines);
  const n = (x: number) => fmtCount(x, locale);
  const items = [
    { key: "resolved", label: t.resolved, hint: h.formsResolved, count: sum.resolved },
    { key: "notFound", label: t.notFound, hint: h.formsNotFound, count: sum.notFound },
    { key: "ambiguous", label: t.ambiguous, hint: h.formsAmbiguous, count: sum.ambiguous },
    { key: "noEmail", label: t.noEmail, hint: h.formsNoEmail, count: sum.noEmail },
    { key: "pending", label: t.pending, hint: h.formsPending, count: sum.pending },
  ] as const;
  return (
    <ul className="flex flex-col gap-2" aria-label={t.resolutionTitle} data-testid="forms-resolution">
      {items.map((i) => {
        const share = sum.submissions === 0 ? null : i.count / sum.submissions;
        return (
          <li key={i.key} className="grid grid-cols-[16rem_1fr_9rem] items-center gap-4 text-small" data-resolution={i.key}>
            <span className="flex items-start font-semibold text-p4a-body" data-hint-anchor="">
              {i.label}
              {hintOf(copy, i.label, i.hint)}
            </span>
            <span className="h-3 rounded-full bg-p4a-neutral-surface">
              <span className={`block h-3 rounded-full ${RESOLUTION_CLASS[i.key]}`} style={{ width: `${((share ?? 0) * 100).toFixed(2)}%` }} />
            </span>
            <span className="tabular text-right text-p4a-muted">{n(i.count)} · {fmtShare(share, locale)}</span>
          </li>
        );
      })}
    </ul>
  );
}

/**
 * The kept answers per form (its markets summed; the market filter narrows them): the form on a row of its
 * own, then per question each option value with the period's and the previous period's submissions, most
 * answered first, the question named on its first row only
 */
export function AnswersTable({ rows, copy, locale }: { rows: FormAnswerRow[]; copy: Copy; locale: Locale }) {
  const t = copy.forms;
  const h = copy.hints;
  const n = (x: number) => fmtCount(x, locale);
  const hint = (label: string, text: string) => hintOf(copy, label, text);
  let index = 0;
  return (
    <div className="overflow-x-auto" data-testid="forms-answers-scroll" role="region" aria-label={t.answersTitle} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="forms-answers">
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.question}>{hint(t.question, h.formsQuestion)}</HintLabel></th>
            <th className={th}><HintLabel label={t.answer}>{hint(t.answer, h.formsAnswer)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.submissions}>{hint(t.submissions, h.formsAnswerCount)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.previous}>{hint(t.previous, h.formsPrevious)}</HintLabel></th>
          </tr>
        </thead>
        {answerGroups(rows).map((g) => (
          <tbody key={g.formKey} data-form={g.formKey}>
            <tr className={zebra(index++)} data-form-name="">
              <td colSpan={4} className="h-10 px-2 font-semibold"><span className="block max-w-[40rem] truncate" title={g.formName}>{g.formName}</span></td>
            </tr>
            {g.fields.flatMap((f) => f.values.map((v, vi) => (
              <tr key={`${f.field}|${v.value}`} className={zebra(index++)} data-field={f.field}>
                <td className="h-10 py-1 pl-8 pr-2 text-small"><span className="block max-w-[16rem] truncate" title={f.field}>{vi === 0 ? f.field : ""}</span></td>
                <td className="h-10 px-2"><span className="block max-w-[22rem] truncate" title={v.value}>{v.value}</span></td>
                <td className={`${td} font-semibold`}>{n(v.submissions)}</td>
                <td className={td}>{n(v.previous)}</td>
              </tr>
            )))}
          </tbody>
        ))}
      </table>
    </div>
  );
}
