import Link from "next/link";
import { MaintenanceFilters } from "@/components/MaintenanceFilters";
import { bucketLabel, MaintenanceDeviceList, MaintenanceGrid, MaintenanceSwitches } from "@/components/MaintenanceParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, LinkButton, Notice, PageTitle } from "@/components/primitives";
import { HeaderHint } from "@/components/HeaderHint";
import { HintLabel } from "@/components/HintLabel";
import { data, dataIsMock } from "@/lib/data";
import {
  fmtMonth, fromMonthChoices, MAINTENANCE_LIST_ROWS, maintenanceQuery, monthOf, parseBucket, parseMaintenanceFilter, parseView,
} from "@/lib/maintenance";
import { holdsAny } from "@/lib/nav";
import { fmtCount, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Maintenance (Report, addition 0008zi, 27 October 2026): what comes due on the devices of the tenant's asset register (a
 * read-only mirror loaded from the register's CSV export), per month, market and model. A component is due on its
 * recorded expiry, else its anchor date plus the rule's interval for the model; its action date is the due date less the
 * rule's lead days; a device's end of life is a due item of its own. The grid shows the Overdue bucket and a column per
 * month of a forward horizon (from a month, 6, 12 or 24 months; H), per market and model, in planned exchanges (a
 * device's items within the bundling window counted once, in the month of the earliest action date) or in components
 * (G); filtered by market (K), model (D) and scope (S: every tracked device, in the field, in stock). A figure opens its
 * device list below; the due items without a due date are a note with a link to Data quality. Team figures only: no
 * figure per person exists. Shown to people holding reports.view or performance.team, as every report's team figures;
 * the database checks again on every read. Ids, statuses, dates and links only, never a customer's name, email, phone or
 * address. The address keys are from, months, market, model, scope, view, bucket, cellMarket and cellModel.
 */
export default async function MaintenancePage({ searchParams }: PageProps<"/reports/maintenance">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.maintenance;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="maintenance">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const currentMonth = monthOf(dateKeyInZone(new Date(), me.timeZone));
  const { filter, problem } = parseMaintenanceFilter(sp, currentMonth);
  const view = parseView(sp.view) ?? "exchanges";
  const report = await data().getMaintenance(me, filter);
  const bucket = parseBucket(sp.bucket, report.buckets);
  const one = (k: string) => { const v = sp[k]; return Array.isArray(v) ? v[0] : v; };
  const cellMarket = /^([A-Z]{2}|unknown)$/.test(one("cellMarket") ?? "") ? one("cellMarket")! : null;
  const cellModel = /^[a-z0-9]+(_[a-z0-9]+)*$/.test(one("cellModel") ?? "") ? one("cellModel")! : null;
  const listFilter = { ...filter, market: cellMarket ?? filter.market, model: cellModel ?? filter.model };
  const list = bucket ? await data().getMaintenanceRows(me, listFilter, bucket, view, MAINTENANCE_LIST_ROWS) : null;

  const base = maintenanceQuery(filter, currentMonth);
  const withView: Record<string, string> = view === "exchanges" ? base : { ...base, view };
  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const fileQuery = new URLSearchParams({
    from: filter.fromMonth, months: String(filter.months), bucket: bucket ?? "all", view,
    ...(listFilter.market ? { market: listFilter.market } : {}), ...(listFilter.model ? { model: listFilter.model } : {}),
    ...(filter.scope ? { scope: filter.scope } : {}),
  });
  const cellModelName = cellModel === "unknown" ? t.unknownModel : report.models.find((m) => m.key === cellModel)?.name ?? cellModel;
  const listTitle = bucket === null ? "" : cellMarket || cellModel
    ? t.listCardCell.replace("{bucket}", bucketLabel(bucket, copy, me.locale))
      .replace("{market}", cellMarket === "unknown" ? copy.reports.unknownMarket : cellMarket ?? "").replace("{model}", cellModelName ?? "")
    : t.listCard.replace("{bucket}", bucketLabel(bucket, copy, me.locale));

  return (
    <Shell copy={copy} me={me} active="maintenance" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted" data-testid="maintenance-note" data-hint-anchor="">
        <HintLabel label={t.note.replace("{days}", String(report.bundleWindowDays))}>
          <HeaderHint label={h.about.replace("{label}", t.exchanges)} text={h.mtWindow} />
        </HintLabel>
      </p>

      <div className="mb-6 flex flex-wrap items-end justify-between gap-6">
        <MaintenanceFilters months={fromMonthChoices(currentMonth).map((m) => ({ key: m, label: fmtMonth(m, me.locale) }))} markets={report.markets}
          models={report.models} fromMonth={filter.fromMonth} currentMonth={currentMonth} market={filter.market} model={filter.model}
          query={Object.fromEntries(Object.entries(withView).filter(([k]) => k !== "from" && k !== "market" && k !== "model"))}
          copy={{ from: t.from, marketFilter: t.marketFilter, allMarkets: t.allMarkets, modelFilter: t.modelFilter, allModels: t.allModels,
            unknownMarket: copy.reports.unknownMarket, unknownModel: t.unknownModel }} />
        <MaintenanceSwitches months={filter.months} scope={filter.scope} view={view} query={withView} copy={copy} />
      </div>

      {problem ? (
        <div className="mb-6">
          <Notice tone="warning">{t.filterIgnored}</Notice>
        </div>
      ) : null}
      {!report.isSetUp ? (
        <div className="mb-6" data-testid="maintenance-not-set-up">
          <Notice tone="info">{t.notSetUp}</Notice>
        </div>
      ) : null}
      {report.unknownItems > 0 ? (
        <div className="mb-6" data-testid="maintenance-unknown">
          <Notice tone="info">
            {t.unknownNote.replace("{n}", n(report.unknownItems))}{" "}
            <Link href="/reports/data-quality" className="font-semibold text-p4a-deepblue underline">{t.unknownLink}</Link>{" · "}
            <Link href={{ pathname: "/reports/maintenance", query: { ...withView, bucket: "unknown" }, hash: "devices" }}
              className="font-semibold text-p4a-deepblue underline">{t.unknownRows}</Link>
          </Notice>
        </div>
      ) : null}

      <div className="flex flex-col gap-6">
        <Card title={t.gridCard}>
          <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted" data-hint-anchor="">
            <HintLabel label={view === "exchanges" ? t.gridIntroExchanges : t.gridIntroComponents}>
              <HeaderHint label={h.about.replace("{label}", t.gridCard)} text={h.mtGrid} />
            </HintLabel>
          </p>
          <p className="mb-4 text-small text-p4a-muted" data-testid="maintenance-devices-line">
            {t.devicesLine.replace("{n}", n(report.devices)).replace("{days}", String(report.bundleWindowDays))}
          </p>
          {report.cells.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p>
            : <MaintenanceGrid report={report} view={view} query={withView} copy={copy} locale={me.locale} />}
        </Card>

        {list && bucket ? (
          <section id="devices" aria-label={listTitle}>
            <Card title={listTitle}>
              <div className="mb-4 flex flex-wrap items-center justify-between gap-4 text-small">
                <span className="text-p4a-muted" data-testid="maintenance-devices-count">
                  {t.listShown.replace("{shown}", n(list.rows.length)).replace("{total}", n(list.total))}
                </span>
                <span className="flex items-center gap-4">
                  <LinkButton href={`/api/v1/reports/maintenance/export?${fileQuery.toString()}`} download shortcut="X" data-shortcut="x" title={t.downloadHint}
                    data-testid="maintenance-download">{t.download}</LinkButton>
                  <Link href={{ pathname: "/reports/maintenance", query: withView }} className="font-semibold text-p4a-deepblue underline">{t.close}</Link>
                </span>
              </div>
              <MaintenanceDeviceList list={list} report={report} copy={copy} locale={me.locale} />
            </Card>
          </section>
        ) : null}
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
