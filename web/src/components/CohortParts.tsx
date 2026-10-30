/**
 * Building blocks of Reports → Lead cohorts (addition 0008zm, 30 October 2026; KPIs 1 and 12): the switches for the cohort's
 * period (G: week or month), the split (B: none, market or source) and the measure (V: attempted, with a conversation,
 * ordered or lost), the table of cohorts by age and the chart of the share ordered by age. Server components, plain SVG, no
 * chart library; the figures come from the data layer and lib/cohorts arranges them. Pulse4all-Style 7.6 for the table
 * (numbers right-aligned, tabular figures, every header with its hint) and 7.7 for the chart (the series order Deep Blue,
 * Leaf Green, Light Blue, Denim, Soft Rose, Inkt; the seventh and eighth cohort repeat the first two colours dashed, so a
 * line is never told apart by colour alone; gridlines and axis labels in their tokens). A dash where a cohort has not
 * reached an age, with the reason in its title. Counts only: no customer data.
 */
import Link from "next/link";
import type { Route } from "next";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { CohortAge, CohortMeasure, CohortSplit, LeadCohortRow } from "@/lib/data";
import { cohortShare, cohortValue, type CohortLine } from "@/lib/cohorts";
import { fmtDays } from "@/lib/funnel";
import { fmtCount, fmtShare } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { Keycap } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

function hintOf(copy: Copy) {
  return function hint(label: string, text: string): ReactNode {
    return <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  };
}

/** One switch: its options as links, the current one marked; the letter moves to the option after the current one */
export function CohortSwitch<T extends string>({ label, letter, options, current, next, href, testId }: {
  label: string; letter: string; options: { value: T; label: string }[]; current: T; next: T;
  href: (value: T) => { pathname: Route; query: Record<string, string> }; testId: string;
}) {
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">{label} <Keycap>{letter.toUpperCase()}</Keycap></span>
      <nav aria-label={label} className="flex flex-wrap gap-2" data-testid={testId}>
        {options.map((o) => (
          <Link
            key={o.value}
            href={href(o.value)}
            aria-current={o.value === current ? "page" : undefined}
            data-shortcut={o.value === next ? letter : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              o.value === current ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {o.label}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** An age's column label: "1 day", "7 days" */
export function ageLabel(age: number, copy: Copy): string {
  const t = copy.leadCohorts;
  return age === 1 ? t.colAgeOne : t.colAge.replace("{n}", String(age));
}

/** One cell of the table: the measure's share of the cohort, its count in the title; a dash with its reason otherwise */
function AgeCell({ age, measure, created, leadToOrderDays, copy, locale }: {
  age: CohortAge; measure: CohortMeasure; created: number; leadToOrderDays: number; copy: Copy; locale: Locale;
}) {
  const t = copy.leadCohorts;
  const value = cohortValue(age, measure);
  if (!age.mature) {
    const title = age.age === 1 ? t.immatureOne : t.immature.replace("{n}", String(age.age));
    return <td className={`${td} text-p4a-muted`} title={title} data-mature="false">–</td>;
  }
  if (value === null) {
    return <td className={`${td} text-p4a-muted`} title={t.aboveOrderDays.replace("{n}", String(leadToOrderDays))} data-mature="true">–</td>;
  }
  return (
    <td className={td} title={t.countTitle.replace("{n}", fmtCount(value, locale)).replace("{created}", fmtCount(created, locale))} data-mature="true">
      {fmtShare(cohortShare(value, created), locale)}
    </td>
  );
}

/** The label of a split row: the market (unknown in words) or the source channel (none in words) */
function groupLabel(group: string | null, split: CohortSplit, copy: Copy): string {
  if (split === "market") return group === null || group === "unknown" ? copy.reports.unknownMarket : group;
  return group ?? copy.leadCohorts.noSource;
}

/**
 * The cohorts newest first, one column per age with the measure's share, then the median days to order and the deals not
 * called yet now; with a split each cohort's markets or source channels under it
 */
export function CohortTable({ rows, ages, measure, split, leadToOrderDays, hints, measureHint, copy, locale }: {
  rows: { cohort: LeadCohortRow; groups: LeadCohortRow[] }[]; ages: number[]; measure: CohortMeasure; split: CohortSplit; leadToOrderDays: number;
  hints: Record<string, string>; measureHint: string; copy: Copy; locale: Locale;
}) {
  const t = copy.leadCohorts;
  const hint = hintOf(copy);
  const n = (x: number) => fmtCount(x, locale);
  const line = (r: LeadCohortRow, sub: boolean) => (
    <tr key={`${r.key}|${r.group ?? ""}|${sub ? 1 : 0}`} className={row} data-testid={sub ? "cohort-group-row" : "cohort-row"} data-cohort={r.key}>
      <td className={`h-10 whitespace-nowrap px-2 ${sub ? "pl-6" : "font-semibold"}`}>
        {sub ? groupLabel(r.group, split, copy) : (
          <span className="flex items-baseline gap-2">
            <span>{r.label}</span>
            <span className="text-caption font-normal text-p4a-muted">{fmtDate(r.start, locale, "short")} – {fmtDate(r.end, locale, "short")}</span>
            {r.partial ? (
              <span className="rounded-button bg-p4a-neutral-surface px-2 text-caption font-semibold text-p4a-muted" title={t.partialTitle} data-testid="cohort-partial">
                {t.partial}
              </span>
            ) : null}
          </span>
        )}
      </td>
      <td className={td}>{n(r.created)}</td>
      {r.ages.map((a) => <AgeCell key={a.age} age={a} measure={measure} created={r.created} leadToOrderDays={leadToOrderDays} copy={copy} locale={locale} />)}
      <td className={td}>{fmtDays(r.medianDaysToOrder, locale, t)}</td>
      <td className={td}>{n(r.notCalledYet)}</td>
    </tr>
  );
  return (
    <div className="overflow-x-auto" data-testid="cohort-table-scroll" role="region" aria-label={t.tableCard} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid="cohort-table" data-measure={measure}>
        <thead>
          <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
            <th className={th}><HintLabel label={t.colCohort}>{hint(t.colCohort, hints.lcCohort!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.colCreated}>{hint(t.colCreated, hints.lcCreated!)}</HintLabel></th>
            {ages.map((a) => (
              <th key={a} className={`${th} text-right`}>
                <HintLabel label={ageLabel(a, copy)}>{hint(ageLabel(a, copy), `${hints.lcAge!} ${measureHint}`)}</HintLabel>
              </th>
            ))}
            <th className={`${th} text-right`}><HintLabel label={t.colMedianDays}>{hint(t.colMedianDays, hints.lcMedianDays!)}</HintLabel></th>
            <th className={`${th} text-right`}><HintLabel label={t.colNotCalled}>{hint(t.colNotCalled, hints.lcNotCalled!)}</HintLabel></th>
          </tr>
        </thead>
        <tbody>
          {rows.flatMap((r) => [line(r.cohort, false), ...r.groups.map((g) => line(g, true))])}
        </tbody>
      </table>
    </div>
  );
}

/** The series order of Pulse4all-Style 7.7; the seventh and eighth line repeat the first two, dashed */
const STROKES = ["stroke-p4a-deepblue", "stroke-p4a-green", "stroke-p4a-lightblue", "stroke-p4a-denim", "stroke-p4a-rose", "stroke-p4a-inkt"];
const FILLS = ["fill-p4a-deepblue", "fill-p4a-green", "fill-p4a-lightblue", "fill-p4a-denim", "fill-p4a-rose", "fill-p4a-inkt"];
const SWATCHES = ["border-p4a-deepblue", "border-p4a-green", "border-p4a-lightblue", "border-p4a-denim", "border-p4a-rose", "border-p4a-inkt"];

/**
 * The share ordered by age, one line per cohort (the newest first in the legend). The ages stand at even steps on the x axis
 * (1, 7, 30 and 90 days apart would crowd the first ages), the share on the y axis from 0 up to the next 10 % above the
 * highest point. Each point carries its cohort, age, share and count in a title
 */
export function CohortChart({ lines, ages, copy, locale }: { lines: CohortLine[]; ages: number[]; copy: Copy; locale: Locale }) {
  const t = copy.leadCohorts;
  const W = 960;
  const H = 280;
  const m = { l: 48, r: 16, t: 12, b: 44 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const highest = Math.max(0, ...lines.flatMap((l) => l.points.map((p) => p.share)));
  const top = Math.max(0.1, Math.ceil(highest * 10) / 10);
  const step = top <= 0.3 ? 0.05 : 0.1;
  const ticks: number[] = [];
  for (let v = 0; v <= top + 1e-9; v += step) ticks.push(Math.round(v * 100) / 100);
  const x = (age: number) => m.l + (ages.length <= 1 ? plotW / 2 : (ages.indexOf(age) / (ages.length - 1)) * plotW);
  const y = (share: number) => m.t + plotH - (share / top) * plotH;
  const days = (age: number) => t.daysValue.replace("{n}", String(age));
  return (
    <div className="flex flex-col gap-4">
      <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={t.chartLabel} data-testid="cohort-chart">
        {ticks.map((v) => (
          <g key={v}>
            <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
            <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{fmtShare(v, locale)}</text>
          </g>
        ))}
        {ages.map((a) => (
          <text key={a} x={x(a)} y={H - 24} textAnchor="middle" fontSize={12} className="fill-p4a-grey tabular">{days(a)}</text>
        ))}
        <text x={m.l + plotW / 2} y={H - 6} textAnchor="middle" fontSize={12} className="fill-p4a-grey">{t.ageAxis}</text>
        {lines.map((l, i) => {
          const stroke = STROKES[i % STROKES.length]!;
          const fill = FILLS[i % FILLS.length]!;
          const dashed = i >= STROKES.length;
          return (
            <g key={l.key} data-testid="cohort-line" data-cohort={l.key}>
              {l.points.length > 1 ? (
                <polyline points={l.points.map((p) => `${x(p.age)},${y(p.share)}`).join(" ")} fill="none" className={stroke} strokeWidth={2}
                  strokeDasharray={dashed ? "6 4" : undefined} />
              ) : null}
              {l.points.map((p) => (
                <circle key={p.age} cx={x(p.age)} cy={y(p.share)} r={4} className={fill}>
                  <title>{`${l.label} · ${days(p.age)}: ${fmtShare(p.share, locale)} (${t.countTitle.replace("{n}", fmtCount(p.count, locale))
                    .replace("{created}", fmtCount(l.created, locale))})`}</title>
                </circle>
              ))}
            </g>
          );
        })}
      </svg>
      <ul className="flex flex-wrap gap-x-6 gap-y-2 text-small" aria-label={t.chartCard} data-testid="cohort-legend">
        {lines.map((l, i) => (
          <li key={l.key} className="flex items-center gap-2">
            <span aria-hidden="true" className={`inline-block w-6 border-t-2 ${SWATCHES[i % SWATCHES.length]} ${i >= STROKES.length ? "border-dashed" : ""}`} />
            <span className="tabular">{l.label}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
