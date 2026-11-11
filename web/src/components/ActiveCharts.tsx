/**
 * The charts of Customers → Active (addition 0009l, brief B35 with addendum A): server components, plain SVG and CSS, no
 * chart library and no client JavaScript (decision D6). Pulse4all-Style 7.7: the series order Deep Blue, Leaf Green,
 * Light Blue, Denim, Soft Rose, Inkt (a seventh and eighth line repeat the first two, dashed); gridlines Border Grey;
 * axis labels 12 px Footnote Grey; a positive delta Leaf Green and a negative one Error, text only. Colour is never the
 * only signal: every mark carries a title naming its series, its point and its value, every chart has a legend with the
 * series' names, and the tables beside the charts hold the same figures. Counts, shares and amounts only.
 */
import type { ReactNode } from "react";
import { niceAxis, sparkPath } from "@/lib/active";

/** The series order of Pulse4all-Style 7.7 */
export const SERIES_STROKE = ["stroke-p4a-deepblue", "stroke-p4a-green", "stroke-p4a-lightblue", "stroke-p4a-denim", "stroke-p4a-rose", "stroke-p4a-inkt"] as const;
export const SERIES_FILL = ["fill-p4a-deepblue", "fill-p4a-green", "fill-p4a-lightblue", "fill-p4a-denim", "fill-p4a-rose", "fill-p4a-inkt"] as const;
export const SERIES_BORDER = ["border-p4a-deepblue", "border-p4a-green", "border-p4a-lightblue", "border-p4a-denim", "border-p4a-rose", "border-p4a-inkt"] as const;
export const SERIES_BG = ["bg-p4a-deepblue", "bg-p4a-green", "bg-p4a-lightblue", "bg-p4a-denim", "bg-p4a-rose", "bg-p4a-inkt"] as const;

const r1 = (v: number) => Math.round(v * 10) / 10;

export interface LinePoint { x: number; y: number; title: string; hollow?: boolean; label?: string }
export interface LineSeries { key: string; label: string; points: LinePoint[]; dashed?: boolean; colour?: number }

/** A legend: a short line in the series' colour (dashed where the line is) and its name */
export function Legend({ items, label }: { items: { key: string; label: string; colour: number; dashed?: boolean; bar?: boolean; className?: string }[]; label: string }) {
  return (
    <ul className="flex flex-wrap gap-x-6 gap-y-2 text-small" aria-label={label} data-testid="active-legend">
      {items.map((s) => (
        <li key={s.key} className="flex items-center gap-2">
          {s.bar
            ? <span aria-hidden="true" className={`inline-block h-3 w-3 rounded-sm ${s.className ?? SERIES_BG[s.colour % SERIES_BG.length]}`} />
            : <span aria-hidden="true" className={`inline-block w-6 border-t-2 ${SERIES_BORDER[s.colour % SERIES_BORDER.length]} ${s.dashed ? "border-dashed" : ""}`} />}
          <span>{s.label}</span>
        </li>
      ))}
    </ul>
  );
}

/**
 * Lines over an even x axis (months, ages, cohort ages): each series a polyline with a point per value, the last point
 * hollow where it is the running month ("so far"). step: a step line (a survival curve holds its value until the next
 * age). markers: vertical lines with a title (a store's subscription history start). refY: a horizontal reference with
 * its label (the 50 % line)
 */
export function LineChart({ series, xLabels, yFormat, yTop, yLabel, xLabel, label, testId, step = false, markers = [], refY, height = 280, width = 960 }: {
  series: LineSeries[]; xLabels: { x: number; text: string }[]; yFormat: (v: number) => string;
  /** The axis's top when it is fixed (a share: 1); a round number above the highest point otherwise */
  yTop?: number; yLabel: string; xLabel?: string; label: string; testId: string; step?: boolean;
  markers?: { x: number; title: string }[]; refY?: { y: number; text: string }; height?: number;
  /** The drawing's width in its own units: 960 for a full-width card, 600 for a half-width one, so the 12 px labels keep their size */
  width?: number;
}) {
  const W = width;
  const H = height;
  const m = { l: 64, r: 24, t: 16, b: xLabel ? 48 : 32 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const xs = series.flatMap((s) => s.points.map((p) => p.x));
  const xMax = Math.max(1, ...xs, ...xLabels.map((l) => l.x));
  const highest = Math.max(0, ...series.flatMap((s) => s.points.map((p) => p.y)));
  const axis = yTop !== undefined ? { top: yTop, bottom: 0, step: yTop / 4 } : niceAxis(0, highest);
  // coordinates to a tenth of a unit: the drawing is the same, the markup a third shorter
  const x = (v: number) => r1(m.l + (v / xMax) * plotW);
  const y = (v: number) => r1(m.t + plotH - (v / axis.top) * plotH);
  const ticks: number[] = [];
  for (let v = 0; v <= axis.top + 1e-9; v += axis.step) ticks.push(v);
  // a point's label stands above the highest series at that x, clear of the lines
  const highestAt = (px: number) => Math.max(...series.flatMap((s) => s.points.filter((p) => p.x === px).map((p) => p.y)));
  const path = (pts: LinePoint[]) => pts.map((p, i) => {
    if (i === 0) return `M${x(p.x)} ${y(p.y)}`;
    return step ? `H${x(p.x)} V${y(p.y)}` : `L${x(p.x)} ${y(p.y)}`;
  }).join(" ");
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={label} data-testid={testId}>
      {ticks.map((v) => (
        <g key={v}>
          <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className="stroke-p4a-border" strokeWidth={1} />
          <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{yFormat(v)}</text>
        </g>
      ))}
      <text x={m.l} y={m.t - 4} fontSize={12} className="fill-p4a-grey">{yLabel}</text>
      {xLabels.map((l) => (
        <text key={l.x} x={x(l.x)} y={H - (xLabel ? 26 : 10)} textAnchor="middle" fontSize={12} className="fill-p4a-grey tabular">{l.text}</text>
      ))}
      {xLabel ? <text x={m.l + plotW / 2} y={H - 6} textAnchor="middle" fontSize={12} className="fill-p4a-grey">{xLabel}</text> : null}
      {markers.map((k) => (
        <g key={`${k.x}-${k.title}`} data-testid="active-marker">
          <title>{k.title}</title>
          <line x1={x(k.x)} x2={x(k.x)} y1={m.t} y2={m.t + plotH} fill="none" className="stroke-p4a-grey" strokeWidth={1} strokeDasharray="2 4" />
          <path d={`M${x(k.x) - 4} ${m.t} h8 l-4 6 z`} className="fill-p4a-grey" />
        </g>
      ))}
      {refY ? (
        <g>
          <line x1={m.l} x2={W - m.r} y1={y(refY.y)} y2={y(refY.y)} fill="none" className="stroke-p4a-inkt" strokeWidth={1} strokeDasharray="6 4" />
          <text x={W - m.r} y={y(refY.y) - 4} textAnchor="end" fontSize={12} className="fill-p4a-grey">{refY.text}</text>
        </g>
      ) : null}
      {series.map((s, i) => {
        const c = (s.colour ?? i) % SERIES_STROKE.length;
        const dashed = s.dashed ?? (s.colour ?? i) >= SERIES_STROKE.length;
        return (
          <g key={s.key} data-testid="active-line" data-series={s.key}>
            {s.points.length > 1 ? <path d={path(s.points)} fill="none" className={SERIES_STROKE[c]} strokeWidth={2} strokeDasharray={dashed ? "6 4" : undefined} /> : null}
            {s.points.map((p) => (
              <g key={p.x}>
                <circle cx={x(p.x)} cy={y(p.y)} r={p.hollow ? 5 : step ? 2.5 : 3.5} className={p.hollow ? `fill-white ${SERIES_STROKE[c]}` : SERIES_FILL[c]}
                  strokeWidth={p.hollow ? 2 : undefined}>
                  <title>{`${s.label} · ${p.title}`}</title>
                </circle>
                {p.label ? <text x={x(p.x)} y={y(highestAt(p.x)) - 12} textAnchor="end" fontSize={12} className="fill-p4a-grey">{p.label}</text> : null}
              </g>
            ))}
          </g>
        );
      })}
    </svg>
  );
}

export interface FlowBar { key: string; label: string; up: { key: string; value: number; label: string }[]; down: number; net: number }

/** The classes of the inflow's stack: Indirect Deep Blue, Direct Light Blue, Unknown Border Grey (named in the legend and in every title) */
export const FLOW_FILL: Record<string, string> = { indirect: "fill-p4a-deepblue", direct: "fill-p4a-lightblue", unknown: "fill-p4a-border" };
export const FLOW_BG: Record<string, string> = { indirect: "bg-p4a-deepblue", direct: "bg-p4a-lightblue", unknown: "bg-p4a-border" };

/** Per month: bars up for the inflow (stacked by acquisition channel), bars down for the outflow (Inkt), and the net change as a line */
export function FlowChart({ bars, xLabels, words, fmt, label, width = 960, height = 280 }: {
  bars: FlowBar[]; xLabels: { x: number; text: string }[]; words: { inflow: string; outflow: string; net: string; axis: string }; fmt: (n: number) => string; label: string;
  width?: number; height?: number;
}) {
  const W = width;
  const H = height;
  const m = { l: 64, r: 24, t: 16, b: 32 };
  const plotW = W - m.l - m.r;
  const plotH = H - m.t - m.b;
  const highest = Math.max(1, ...bars.map((b) => b.up.reduce((n, u) => n + u.value, 0)), ...bars.map((b) => b.net));
  const lowest = Math.min(0, ...bars.map((b) => -b.down), ...bars.map((b) => b.net));
  const axis = niceAxis(lowest, highest);
  const span = axis.top - axis.bottom;
  const y = (v: number) => r1(m.t + ((axis.top - v) / span) * plotH);
  const band = plotW / Math.max(1, bars.length);
  const barW = r1(Math.min(28, band * 0.6));
  const cx = (i: number) => r1(m.l + i * band + band / 2);
  const ticks: number[] = [];
  for (let v = axis.bottom; v <= axis.top + 1e-9; v += axis.step) ticks.push(v);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="block h-auto w-full" role="img" aria-label={label} data-testid="active-flow">
      {ticks.map((v) => (
        <g key={v}>
          <line x1={m.l} x2={W - m.r} y1={y(v)} y2={y(v)} fill="none" className={v === 0 ? "stroke-p4a-grey" : "stroke-p4a-border"} strokeWidth={1} />
          <text x={m.l - 8} y={y(v) + 4} textAnchor="end" fontSize={12} className="fill-p4a-grey tabular">{fmt(v)}</text>
        </g>
      ))}
      <text x={m.l} y={m.t - 4} fontSize={12} className="fill-p4a-grey">{words.axis}</text>
      {bars.map((b, i) => {
        let below = 0;
        return (
          <g key={b.key}>
            {b.up.map((u) => {
              if (u.value <= 0) return null;
              const top = y(below + u.value);
              const h = y(below) - top;
              below += u.value;
              return (
                <rect key={u.key} x={r1(cx(i) - barW / 2)} y={top} width={barW} height={r1(Math.max(0, h))} className={FLOW_FILL[u.key] ?? "fill-p4a-border"} data-channel={u.key}>
                  <title>{`${b.label} · ${words.inflow}, ${u.label}: ${fmt(u.value)}`}</title>
                </rect>
              );
            })}
            {b.down > 0 ? (
              <rect x={r1(cx(i) - barW / 2)} y={y(0)} width={barW} height={r1(Math.max(0, y(-b.down) - y(0)))} className="fill-p4a-inkt">
                <title>{`${b.label} · ${words.outflow}: ${fmt(b.down)}`}</title>
              </rect>
            ) : null}
          </g>
        );
      })}
      {bars.length > 1 ? <polyline points={bars.map((b, i) => `${cx(i)},${y(b.net)}`).join(" ")} fill="none" className="stroke-p4a-green" strokeWidth={2} /> : null}
      {bars.map((b, i) => (
        <circle key={b.key} cx={cx(i)} cy={y(b.net)} r={3} className="fill-p4a-green">
          <title>{`${b.label} · ${words.net}: ${b.net > 0 ? "+" : b.net < 0 ? "−" : ""}${fmt(Math.abs(b.net))}`}</title>
        </circle>
      ))}
      {xLabels.map((l) => <text key={l.x} x={cx(l.x)} y={H - 10} textAnchor="middle" fontSize={12} className="fill-p4a-grey tabular">{l.text}</text>)}
    </svg>
  );
}

/** A sparkline: 80 by 20, no axes, its title naming the first and the last value */
export function Sparkline({ values, title }: { values: number[]; title: string }) {
  if (values.length === 0) return <span className="text-p4a-muted">–</span>;
  return (
    <svg viewBox="0 0 80 20" width={80} height={20} role="img" aria-label={title} className="inline-block align-middle" data-testid="active-spark">
      <title>{title}</title>
      <path d={sparkPath(values, 80, 20)} fill="none" className="stroke-p4a-deepblue" strokeWidth={1.5} />
    </svg>
  );
}

/** Horizontal bars with their label and value beside them (a histogram's bands, a mix's parts): the bar's length against the largest */
export function Bars({ rows, label, testId, colour = "bg-p4a-deepblue" }: {
  rows: { key: string; label: ReactNode; value: number; text: string; title: string; href?: ReactNode }[]; label: string; testId: string; colour?: string;
}) {
  const largest = Math.max(1, ...rows.map((r) => r.value));
  return (
    <ul className="flex flex-col gap-2" aria-label={label} data-testid={testId}>
      {rows.map((r) => (
        <li key={r.key} className="grid grid-cols-[minmax(6rem,9rem)_1fr_auto] items-center gap-3 text-small" title={r.title}>
          <span className="truncate">{r.label}</span>
          <span className="h-3 rounded-full bg-p4a-neutral-surface">
            <span className={`block h-3 rounded-full ${colour}`} style={{ width: `${(r.value / largest) * 100}%` }} />
          </span>
          <span className="tabular text-right">{r.text}</span>
        </li>
      ))}
    </ul>
  );
}
