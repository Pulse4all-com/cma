/**
 * Building blocks of Reports → Maintenance (addition 0008zi): the switches (horizon, scope, view), the grid (one row per
 * market and model, Overdue then a column per month, each figure a link to its device list) and the device list. Server
 * components, plain CSS; Pulse4all-Style 7.5 and 7.6: the header row Background Blue, numbers right-aligned with tabular
 * figures, zebra rows, a muted 0; every header with its hint. Team figures only, never a person's; ids, statuses, dates and
 * links only, never a customer's name, email, phone or address.
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { MaintenanceReport, MaintenanceRows, MaintenanceScope, MaintenanceView } from "@/lib/data";
import { cellTitle, cellValue, fmtMonth, maintenanceGrid, MAINTENANCE_HORIZONS, MAINTENANCE_VIEWS } from "@/lib/maintenance";
import { fmtCount } from "@/lib/reports";
import { fmtDate } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { RecordLink } from "./RecordLink";
import { Keycap } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";
const pill = (active: boolean) => [
  "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
  active ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
].join(" ");

type Query = Record<string, string>;
const PATH = "/reports/maintenance";

function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

function Hint({ label, text, copy }: { label: string; text: string; copy: Copy }) {
  return <HintLabel label={label}><HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} /></HintLabel>;
}

/** A row of links that switch one value of the address, the next one under a key */
function Switch<T extends string | number>({ label, hint, keycap, values, current, names, query, param, testId, copy }: {
  label: string; hint?: string; keycap: string; values: readonly T[]; current: T; names: Record<string, string>; query: Query; param: string; testId: string;
  copy: Copy;
}) {
  const i = values.indexOf(current);
  const next = values[(i + 1) % values.length];
  return (
    <div className="flex flex-col gap-2 text-small font-semibold" data-hint-anchor="">
      <span className="flex items-center gap-2">
        {hint ? <Hint label={label} text={hint} copy={copy} /> : label} <Keycap>{keycap.toUpperCase()}</Keycap>
      </span>
      <nav aria-label={label} className="flex flex-wrap gap-2" data-testid={testId}>
        {values.map((v) => {
          const q: Query = { ...query };
          if (String(v) === "") delete q[param]; else q[param] = String(v);
          return (
            <Link key={String(v)} href={{ pathname: PATH, query: q }} aria-current={v === current ? "page" : undefined}
              data-shortcut={v === next ? keycap : undefined} className={pill(v === current)}>
              {names[String(v)]}
            </Link>
          );
        })}
      </nav>
    </div>
  );
}

/** The horizon (H: 6, 12 or 24 months), the scope (S: every tracked device, in the field, in stock) and the view (G) */
export function MaintenanceSwitches({ months, scope, view, query, copy }: {
  months: number; scope: MaintenanceScope | null; view: MaintenanceView; query: Query; copy: Copy;
}) {
  const t = copy.maintenance;
  const h = copy.hints;
  const horizons = MAINTENANCE_HORIZONS as readonly number[];
  return (
    <div className="flex flex-wrap items-end gap-6">
      <Switch label={t.horizon} keycap="h" values={horizons.includes(months) ? horizons : [...horizons, months]} current={months} param="months"
        names={Object.fromEntries([...horizons, months].map((n) => [String(n), t.horizonMonths.replace("{n}", String(n))]))} query={query}
        testId="maintenance-horizon" copy={copy} />
      <Switch label={t.scope} hint={h.mtDevices} keycap="s" values={["", "field", "stock"] as const} current={scope ?? ""} param="scope"
        names={{ "": t.scopeAll, field: t.scopeField, stock: t.scopeStock }} query={query} testId="maintenance-scope" copy={copy} />
      <Switch label={t.view} hint={view === "exchanges" ? h.mtExchanges : h.mtComponents} keycap="g" values={MAINTENANCE_VIEWS} current={view} param="view"
        names={{ exchanges: t.viewExchanges, components: t.viewComponents }} query={query} testId="maintenance-view" copy={copy} />
    </div>
  );
}

/** A bucket's column label: Overdue, or the month */
export function bucketLabel(bucket: string, copy: Copy, locale: Locale): string {
  if (bucket === "overdue") return copy.maintenance.listOverdue;
  if (bucket === "unknown") return copy.maintenance.listUnknown;
  if (bucket === "all") return copy.maintenance.listAll;
  return fmtMonth(bucket, locale);
}

const marketName = (m: string, copy: Copy) => (m === "unknown" ? copy.reports.unknownMarket : m);
const modelName = (key: string, name: string | null, copy: Copy) => (key === "unknown" ? copy.maintenance.unknownModel : name ?? key);

/**
 * The grid: per market and model, Overdue then the months of the horizon and the row's total, in the view's figure; the
 * total per column. A figure above 0 links to its device list (the address keys bucket, cellMarket and cellModel)
 */
export function MaintenanceGrid({ report, view, query, copy, locale }: { report: MaintenanceReport; view: MaintenanceView; query: Query; copy: Copy; locale: Locale }) {
  const t = copy.maintenance;
  const h = copy.hints;
  const n = (x: number) => fmtCount(x, locale);
  const grid = maintenanceGrid(report, view);
  const labels = { endOfLife: t.endOfLife, exchanges: t.exchanges };
  const cellLink = (bucket: string, value: number, title: string, cell?: { market: string; model: string }) => {
    if (value === 0) return <span className="text-p4a-muted">{n(0)}</span>;
    const q: Query = { ...query, view, bucket, ...(cell ? { cellMarket: cell.market, cellModel: cell.model } : {}) };
    return (
      <Link href={{ pathname: PATH, query: q, hash: "devices" }} title={title} className="font-semibold text-p4a-deepblue underline-offset-2 hover:underline"
        data-maintenance-cell={`${bucket}|${cell?.market ?? "*"}|${cell?.model ?? "*"}`}>
        {n(value)}
      </Link>
    );
  };
  return (
    <Scroll testId="maintenance-grid" label={t.gridCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><Hint label={t.colMarket} text={h.mtColMarket} copy={copy} /></th>
          <th className={th}><Hint label={t.colModel} text={h.mtColModel} copy={copy} /></th>
          {report.buckets.map((b) => (
            <th key={b} className={`${th} text-right`} data-bucket={b}>
              <Hint label={b === "overdue" ? t.colOverdue : fmtMonth(b, locale)} text={b === "overdue" ? h.mtColOverdue : h.mtColMonth} copy={copy} />
            </th>
          ))}
          <th className={`${th} text-right`}><Hint label={t.colTotal} text={h.mtColTotal} copy={copy} /></th>
        </tr>
      </thead>
      <tbody>
        {grid.rows.map((r) => (
          <tr key={`${r.market}|${r.model}`} className={row} data-row={`${r.market}|${r.model}`}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{marketName(r.market, copy)}</td>
            <td className="h-10 whitespace-nowrap px-2">{modelName(r.model, r.modelName, copy)}</td>
            {report.buckets.map((b) => (
              <td key={b} className={td}>
                {cellLink(b, cellValue(r.cells[b], view), cellTitle(r.cells[b], report.componentKinds, labels), { market: r.market, model: r.model })}
              </td>
            ))}
            <td className={`${td} font-semibold`}>{n(r.total)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr className="text-p4a-body font-semibold" data-row="total">
          <td className="h-10 whitespace-nowrap px-2" colSpan={2}>{t.totalRow}</td>
          {report.buckets.map((b) => <td key={b} className={td}>{cellLink(b, grid.totals[b] ?? 0, "")}</td>)}
          <td className={td}>{n(grid.total)}</td>
        </tr>
      </tfoot>
    </Scroll>
  );
}

/**
 * The device list of a cell: per device (and planned exchange) the serial number, model, market, device status, the
 * components due, the due date, the basis, the action date, the customer and subscription ids, the customer record and the
 * device's row in the register, each a link where its connection has a template. No name, email, phone or address
 */
export function MaintenanceDeviceList({ list, report, copy, locale }: { list: MaintenanceRows; report: MaintenanceReport; copy: Copy; locale: Locale }) {
  const t = copy.maintenance;
  const h = copy.hints;
  const kindName = new Map<string, string>([...report.componentKinds.map((k) => [k.key, k.name] as [string, string]), ["device", t.component_device]]);
  const basis: Record<string, string> = { recorded: t.basis_recorded, rule: t.basis_rule, unknown: t.basis_unknown };
  const date = (k: string | null) => (k ? fmtDate(k, locale, "short") : <span className="text-p4a-muted">–</span>);
  const text = (v: string | null) => v ?? <span className="text-p4a-muted">–</span>;
  const head = (label: string, hint: string, right = false) => <th className={`${th}${right ? " text-right" : ""}`}><Hint label={label} text={hint} copy={copy} /></th>;
  if (list.rows.length === 0) return <p className="text-body text-p4a-muted">{t.listEmpty}</p>;
  return (
    <Scroll testId="maintenance-devices" label={t.listAll}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          {head(t.colSerial, h.mtColSerial)}
          {head(t.colModel, h.mtColModel)}
          {head(t.colMarket, h.mtColMarket)}
          {head(t.colStatus, h.mtColStatus)}
          {head(t.colComponents, h.mtColComponents)}
          {head(t.colDueDate, h.mtDueDate)}
          {head(t.colBasis, h.mtBasis)}
          {head(t.colActionDate, h.mtActionDate)}
          {head(t.colCustomer, h.mtColCustomer)}
          {head(t.colSubscription, h.mtColSubscription)}
          {head(t.colContact, h.mtColContact)}
          {head(t.colRegister, h.mtColRegister)}
        </tr>
      </thead>
      <tbody>
        {list.rows.map((r) => (
          <tr key={`${r.deviceId}|${r.bucket}|${r.exchangeOn ?? ""}`} className={row} data-device={r.sourceId}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold tabular">{r.serial ?? <span className="font-normal text-p4a-muted">{t.noSerial}</span>}</td>
            <td className="h-10 whitespace-nowrap px-2">{modelName(r.model, r.modelName, copy)}</td>
            <td className="h-10 whitespace-nowrap px-2">{marketName(r.market, copy)}</td>
            <td className="h-10 whitespace-nowrap px-2">{text(r.deviceStatusName ?? r.deviceStatus)}</td>
            <td className="h-10 whitespace-nowrap px-2">{r.components.map((c) => kindName.get(c) ?? c).join(", ")}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{date(r.dueOn)}</td>
            <td className="h-10 whitespace-nowrap px-2">{r.bases.map((b) => basis[b] ?? b).join(", ")}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{date(r.actionOn)}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{text(r.customerRef)}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">{text(r.subscriptionRef)}</td>
            <td className="h-10 whitespace-nowrap px-2 tabular">
              {r.crmContactId ? <span className="inline-flex items-center gap-1">{r.crmContactId} <RecordLink url={r.contactUrl} label={t.openContact} /></span> : text(null)}
            </td>
            <td className="h-10 whitespace-nowrap px-2 tabular">
              <span className="text-p4a-muted">{r.sourceId}</span>
            </td>
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}
