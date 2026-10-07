/**
 * The Dashboard's tiles and charts (Pulse4all-Style.md 7.7): server components, plain SVG and
 * CSS, no chart library. Colours come from the flag groups in lib/dashboard, never from a status
 * key or name, and every coloured mark carries its label or a title, so colour is never the only
 * signal. Gridlines Border Grey, axis labels 12 px Footnote Grey.
 */
import type { Copy, Locale } from "@/lib/copy";
import {
  GROUP_BG, GROUP_FILL, GROUPS, hoursAxis, share, type DayTotal, type Group, type GroupSeconds,
  type PersonTotal, type StatusTotal,
} from "@/lib/dashboard";
import { fmtDate, fmtMinutes, fmtPercent } from "@/lib/time";
import { Badge } from "./primitives";

const minutes = (seconds: number) => fmtMinutes(Math.floor(seconds / 60));

export function groupLabels(copy: Copy): Record<Group, { label: string; hint: string }> {
  const t = copy.dashboard;
  return {
    productive: { label: t.groupProductive, hint: t.groupProductiveHint },
    otherWork: { label: t.groupOtherWork, hint: t.groupOtherWorkHint },
    paidPause: { label: t.groupPaidPause, hint: t.groupPaidPauseHint },
    unpaidPause: { label: t.groupUnpaidPause, hint: t.groupUnpaidPauseHint },
  };
}

/** A small colour mark; always next to a label */
export function Swatch({ group }: { group: Group | "pause" }) {
  return <span aria-hidden="true" className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${GROUP_BG[group]}`} />;
}

export function Tile({ label, value, hint }: { label: string; value: string; hint: string }) {
  return (
    <div className="rounded-card border border-p4a-border bg-white p-5">
      <p className="text-caption text-p4a-grey">{label}</p>
      <p className="tabular mt-1 text-title font-bold text-p4a-heading">{value}</p>
      <p className="mt-1 text-small text-p4a-muted">{hint}</p>
    </div>
  );
}

/**
 * The four groups with their totals: the key to every chart below it. Times only: the shares sit
 * in Time per status, so the Productive tile (share of worked time) is the only percentage of its kind.
 */
export function GroupLegend({ groups, copy }: { groups: GroupSeconds; copy: Copy }) {
  const labels = groupLabels(copy);
  return (
    <ul aria-label={copy.dashboard.groups} className="flex flex-wrap gap-x-8 gap-y-2 text-small">
      {GROUPS.map((g) => (
        <li key={g} className="flex items-center gap-2" title={labels[g].hint}>
          <Swatch group={g} />
          <span className="font-semibold text-p4a-body">{labels[g].label}</span>
          <span className="tabular text-p4a-muted">{minutes(groups[g])}</span>
        </li>
      ))}
    </ul>
  );
}

/** One bar per status in the tenant's order; the bar's length is scaled to the largest status, the share of clocked time is printed next to it */
export function StatusBars({
  statuses, clockedSeconds, copy, locale,
}: { statuses: StatusTotal[]; clockedSeconds: number; copy: Copy; locale: Locale }) {
  const t = copy.dashboard;
  const largest = Math.max(1, ...statuses.map((s) => s.seconds));
  const th = "h-10 whitespace-nowrap px-3 font-semibold";
  return (
    <table className="w-full border-collapse text-body">
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={`${th} w-56`}>{t.status}</th>
          <th className={th}><span className="sr-only">{t.byStatusHint}</span></th>
          <th className={`${th} w-28 text-right`}>{t.time}</th>
          <th className={`${th} w-24 text-right`}>{t.share}</th>
        </tr>
      </thead>
      <tbody>
        {statuses.map((s) => (
          <tr key={s.key} className="border-b border-p4a-border last:border-b-0">
            <td className="h-10 px-3">
              <span className="flex items-center gap-2">
                <Swatch group={s.group} />
                <span>{s.name}</span>
                {s.active ? null : <Badge tone="neutral">{t.inactive}</Badge>}
              </span>
            </td>
            <td className="px-3">
              <div className="h-3 w-full rounded-full bg-p4a-neutral-surface">
                <div
                  className={`h-3 rounded-full ${GROUP_BG[s.group]}`}
                  style={{ width: `${(s.seconds / largest) * 100}%` }}
                />
              </div>
            </td>
            <td className="tabular px-3 text-right">{minutes(s.seconds)}</td>
            <td className="tabular px-3 text-right text-p4a-muted">{fmtPercent(share(s.seconds, clockedSeconds), locale)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/**
 * Columns per day, stacked bottom to top in group order. Drawn in a fixed viewBox that scales with
 * the card, so the text scales too (12 units at the 1280 px minimum).
 */
export function DayChart({ days, copy, locale }: { days: DayTotal[]; copy: Copy; locale: Locale }) {
  const labels = groupLabels(copy);
  const W = 960;
  const H = 260;
  const m = { l: 44, r: 8, t: 12, b: 30 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const axis = hoursAxis(Math.max(0, ...days.map((d) => d.seconds)));
  const y = (seconds: number) => m.t + plotH - (seconds / 3600 / axis.top) * plotH;
  const band = plotW / Math.max(1, days.length);
  const barW = Math.min(44, band * 0.6);
  const labelEvery = Math.ceil(days.length / 12);
  const ticks: number[] = [];
  for (let h = 0; h <= axis.top; h += axis.step) ticks.push(h);

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={copy.dashboard.byDayLabel}>
      {ticks.map((h) => (
        <g key={h}>
          <line x1={m.l} x2={W - m.r} y1={y(h * 3600)} y2={y(h * 3600)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
          <text x={m.l - 8} y={y(h * 3600) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">
            {h}h
          </text>
        </g>
      ))}
      {days.map((d, i) => {
        const x = m.l + i * band + (band - barW) / 2;
        let below = 0;
        return (
          <g key={d.date}>
            <title>{`${fmtDate(d.date, locale, "compact")}: ${minutes(d.seconds)}`}</title>
            {GROUPS.map((g) => {
              const s = d.groups[g];
              if (s <= 0) return null;
              const top = y(below + s);
              const height = y(below) - top;
              below += s;
              return (
                <rect key={g} x={x} y={top} width={barW} height={Math.max(0, height)} className={GROUP_FILL[g]}>
                  <title>{`${fmtDate(d.date, locale, "compact")} · ${labels[g].label}: ${minutes(s)}`}</title>
                </rect>
              );
            })}
            {i % labelEvery === 0 ? (
              <text x={m.l + i * band + band / 2} y={H - 10} textAnchor="middle" fontSize={12} className="fill-p4a-grey">
                {fmtDate(d.date, locale, days.length <= 7 ? "compact" : "short")}
              </text>
            ) : null}
          </g>
        );
      })}
    </svg>
  );
}

/** One stacked bar per person, by name, against the longest clocked time in the list */
export function PersonBars({ people, copy }: { people: PersonTotal[]; copy: Copy }) {
  const t = copy.dashboard;
  const labels = groupLabels(copy);
  const longest = Math.max(1, ...people.map((p) => p.clockedSeconds));
  const th = "h-10 whitespace-nowrap px-3 font-semibold";
  return (
    <table className="w-full border-collapse text-body">
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={`${th} w-56`}>{t.person}</th>
          <th className={th}><span className="sr-only">{t.groups}</span></th>
          <th className={`${th} w-28 text-right`}>{t.worked}</th>
          <th className={`${th} w-28 text-right`}>{t.paid}</th>
        </tr>
      </thead>
      <tbody>
        {people.map((p) => (
          <tr key={p.userId} className="border-b border-p4a-border last:border-b-0">
            <td className="px-3 py-2">
              <span className="block">{p.displayName}</span>
              <span className="block text-caption text-p4a-muted">{p.organisationName}</span>
            </td>
            <td className="px-3">
              <div
                className="flex h-3 overflow-hidden rounded-full bg-p4a-neutral-surface"
                style={{ width: `${(p.clockedSeconds / longest) * 100}%` }}
              >
                {GROUPS.map((g) =>
                  p.groups[g] > 0 ? (
                    <div
                      key={g}
                      title={`${labels[g].label}: ${minutes(p.groups[g])}`}
                      className={`h-3 ${GROUP_BG[g]}`}
                      style={{ width: `${(p.groups[g] / p.clockedSeconds) * 100}%` }}
                    />
                  ) : null,
                )}
              </div>
            </td>
            <td className="tabular px-3 text-right">{fmtMinutes(p.workedMinutes)}</td>
            <td className="tabular px-3 text-right text-p4a-muted">{fmtMinutes(p.paidMinutes)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
