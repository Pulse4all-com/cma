import { Suspense } from "react";
import { FlashMarket, FlashModel } from "@/components/FlashControls";
import { FleetMap } from "@/components/FleetMap";
import { FleetPushButton } from "@/components/FleetPushButton";
import { ListSkeleton } from "@/components/InstalledBase";
import { PlaceholderBody } from "@/components/PlaceholderPage";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Badge, Notice, PageTitle } from "@/components/primitives";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { data, dataIsMock, requestDbTrace, streamed, type FleetArea, type FleetPageTiles, type FleetRow, type FleetRowsPage, type FleetState } from "@/lib/data";
import {
  areaCountOf, FLEET_DUMMY_TILES, FLEET_PATH, FLEET_STATE_SWATCH, FLEET_TILES, fleetHref, fleetQueryOf, fleetRowsQueryOf, fleetStateOf,
  type FleetAddressState,
} from "@/lib/fleet-management";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { fmtDateTimeShort } from "@/lib/time";

/**
 * Assets → Fleet management (addition 0009t; Martin, 16 November 2026, brief B37, D1 to D8; brief B38, E1 to E6). With the
 * tenant's fleet_management.dummy_preview on: the title, the Preview banner (the locations and states are dummy data, the
 * devices and their past-due items real), the Market (K) and Model (D) filters as Installed base's (market, f_model), seven
 * tiles (In the field and Devices past due as Installed base counts them, the latter saying how many are not in the field,
 * E3; Monitored and the four monitoring states with a small Dummy badge) that filter the map and the list (f_state), the
 * map (components/FleetMap) and the side panel: the devices that need attention by default, a selected area's counts and
 * devices otherwise (area), 50 a page (page). Off: the placeholder as before (D6). One read (E6, cma.fleet_page): the
 * tiles, the areas and the list's first page; a further page of the list is read after the first paint (cma.fleet_rows).
 * Team figures only, for reports.view or performance.team; the database checks again on every read. Serials, ids, codes,
 * place names, dates and counts: never a customer reference, name, email, phone or address.
 */
export async function FleetManagement({ searchParams, me, copy }: {
  searchParams: Record<string, string | string[] | undefined>;
  me: Principal;
  copy: Copy;
}) {
  const title = copy.nav.fleetManagement;
  const t = copy.fleet;
  const locale = me.locale;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="fleet-management">
        <PageTitle>{title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const st = fleetStateOf(searchParams);
  // a further page of the list: its own read, alongside the page's (never before the first paint waits for it)
  const laterRead = st.page > 1
    ? streamed(() => data().getFleetRows(me, fleetRowsQueryOf(st))).then((page) => ({ page, error: null }), (error: unknown) => ({ page: null, error }))
    : null;
  // the page's one read (E6): the tiles, the areas and the list's first page from one computation of the devices
  const doc = await data().getFleetPage(me, { market: st.market, model: st.model, state: st.tile, areaId: st.areaId });
  const rowsRead: Promise<{ page: FleetRowsPage | null; error: unknown }> = laterRead ?? Promise.resolve({ page: doc.list, error: null });

  if (!doc.setUp) {
    return (
      <Shell copy={copy} me={me} active="fleet-management">
        <PageTitle>{title}</PageTitle>
        <PlaceholderBody intro={copy.placeholders.intro_fleetManagement} fedBy={copy.placeholders.fedBy_fleetManagement} flash={null} me={me} copy={copy} />
      </Shell>
    );
  }

  const tiles = doc.tiles;
  // the devices In the field without an area under the tile; the devices past due outside the field (in stock, internal
  // use) are no device In the field: a note of their own (Martin, 16 November 2026, on #285)
  const noAreaRow = doc.areas.find((a) => a.areaId === null);
  const withoutArea = noAreaRow ? areaCountOf(noAreaRow, st.tile) : 0;
  const notInField = st.tile === null || st.tile === "past_due" ? doc.pastDueNotInField : 0;
  const selected = st.areaId ? doc.areas.find((a) => a.areaId === st.areaId) ?? null : null;
  const nf = new Intl.NumberFormat(locale);
  const modelName = (key: string) => (key === "unknown" ? copy.flash.unknownModel : doc.models.find((m) => m.key === key)?.name ?? key);
  // what the filters keep: a market or model change starts again without an area or a page
  const filterQuery = fleetQueryOf({ market: st.market, model: st.model, tile: st.tile, areaId: null, page: 1 });
  const mapQuery = fleetQueryOf({ ...st, areaId: null, page: 1 });
  const markets = doc.markets.filter((m) => m.code !== "unknown").map((m) => ({ code: m.code, name: m.name ?? m.code }));

  return (
    <Shell copy={copy} me={me} active="fleet-management" wide>
      <PageTitle>{title}</PageTitle>
      <p className="-mt-4 mb-6 max-w-4xl text-body text-p4a-muted">{t.intro}</p>
      <div className="mb-6" data-testid="fleet-preview-banner">
        <Notice tone="info">
          <span className="mr-2"><Badge tone="info">{t.previewBadge}</Badge></span>
          {t.previewBanner}
        </Notice>
      </div>

      <div className="mb-6 flex flex-wrap items-end gap-6">
        <FlashMarket market={st.market} markets={markets} query={filterQuery} path={FLEET_PATH}
          labels={{ market: copy.flash.market, allMarkets: copy.flash.allMarkets, unknownMarket: copy.flash.unknownMarket }} />
        <FlashModel model={st.model} models={doc.models} query={filterQuery} path={FLEET_PATH}
          labels={{ model: copy.flash.modelFilter, allModels: copy.flash.allModels, unknownModel: copy.flash.unknownModel }} />
      </div>
      {st.problem ? <div className="mb-4"><Notice tone="warning">{copy.flash.filterIgnored}</Notice></div> : null}

      <Tiles st={st} tiles={tiles} t={t} nf={nf} />

      <div className="grid gap-6 xl:grid-cols-[minmax(0,1fr)_400px]">
        <section className="min-w-0 rounded-card border border-p4a-border bg-white p-6" aria-labelledby="fleet-map-title" data-testid="fleet-map-card">
          <h2 id="fleet-map-title" className="mb-4 text-panel font-semibold text-p4a-heading">{t.mapTitle}</h2>
          <FleetMap areas={doc.areas} tile={st.tile} markets={markets.map((m) => m.code)} selectedAreaId={st.areaId} query={mapQuery} locale={locale}
            labels={{ mapLabel: t.mapLabel, allMarkets: copy.flash.allMarkets, zoomIn: t.zoomIn, zoomOut: t.zoomOut, clusterArea: t.clusterArea, clusterGroup: t.clusterGroup }} />
          <p className="mt-3 text-caption text-p4a-grey">{t.mapNote}</p>
          {withoutArea > 0 ? (
            <p className="mt-1 text-small text-p4a-muted" data-testid="fleet-without-area">
              {withoutArea === 1 ? t.withoutAreaOne : t.withoutArea.replace("{n}", nf.format(withoutArea))}
            </p>
          ) : null}
          {notInField > 0 ? (
            <p className="mt-1 text-small text-p4a-muted" data-testid="fleet-past-due-not-in-field">
              {notInField === 1 ? t.pastDueNotInFieldOne : t.pastDueNotInField.replace("{n}", nf.format(notInField))}
            </p>
          ) : null}
        </section>

        <section className="min-w-0 rounded-card border border-p4a-border bg-white p-6" aria-labelledby="fleet-panel-title" data-testid="fleet-panel">
          <h2 id="fleet-panel-title" className="mb-4 text-panel font-semibold text-p4a-heading">
            {selected ? t.areaTitle.replace("{code}", selected.areaCode ?? "").replace("{area}", selected.label ?? "")
              : st.tile ? t.stateTitle.replace("{tile}", t[`tile_${st.tile}`]) : t.attentionTitle}
          </h2>
          {selected ? <AreaCounts area={selected} t={t} nf={nf} /> : null}
          {st.areaId ? (
            <p className="mb-4">
              <FleetPushButton href={fleetHref(fleetQueryOf({ ...st, areaId: null, page: 1 }))} testId="fleet-clear-area"
                className="text-small font-semibold text-p4a-deepblue underline-offset-2 hover:underline">
                {t.clearArea}
              </FleetPushButton>
            </p>
          ) : null}
          <Suspense fallback={<ListSkeleton label={t.loading} rows={8} />}>
            <FleetList read={rowsRead} st={st} t={t} modelName={modelName} timeZone={doc.timeZone ?? me.timeZone} locale={locale}
              leadWithWhy={st.areaId === null && (st.tile === null || st.tile === "past_due")} />
          </Suspense>
        </section>
      </div>

      {dataIsMock ? <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div> : null}
    </Shell>
  );
}

/**
 * The seven tiles (the brief's order); a tile filters the map and the list, again to show every device in the field.
 * Devices past due says how many of them are not in the field (E3), the figure itself Installed base's (D2)
 */
function Tiles({ st, tiles, t, nf }: { st: FleetAddressState; tiles: FleetPageTiles; t: Copy["fleet"]; nf: Intl.NumberFormat }) {
  return (
    <div role="group" aria-label={t.tilesLabel} className="mb-6 grid grid-cols-2 gap-4 md:grid-cols-4 xl:grid-cols-7" data-testid="fleet-tiles">
      {FLEET_TILES.map((k) => {
        const active = st.tile === k;
        const label = t[`tile_${k}`];
        return (
          <FleetPushButton key={k} href={fleetHref(fleetQueryOf({ ...st, tile: active ? null : k, page: 1 }))} pressed={active} testId={`fleet-tile-${k}`}
            label={active ? t.tileShowAll.replace("{tile}", label) : undefined}
            className="flex min-w-0 flex-col items-start rounded-card border border-p4a-border bg-white p-4 text-left hover:border-p4a-deepblue aria-pressed:border-2 aria-pressed:border-p4a-deepblue">
            <span className="flex min-h-9 items-start gap-2 text-caption text-p4a-grey">
              {k === "ready" || k === "needs_attention" || k === "no_connection" || k === "not_monitored"
                ? <span className={`mt-0.5 inline-block h-3 w-3 shrink-0 rounded-full ${FLEET_STATE_SWATCH[k]}`} aria-hidden="true" /> : null}
              {label}
            </span>
            <span className="tabular mt-1 text-title font-bold text-p4a-heading" data-testid={`fleet-tile-${k}-value`}>{nf.format(tiles[k])}</span>
            {k === "past_due" && tiles.past_due_not_in_field > 0 ? (
              <span className="mt-1 text-caption text-p4a-muted" data-testid="fleet-tile-past_due-not-in-field">
                {t.tile_past_due_not_in_field.replace("{n}", nf.format(tiles.past_due_not_in_field))}
              </span>
            ) : null}
            {FLEET_DUMMY_TILES.has(k) ? <span className="mt-1"><Badge tone="neutral">{t.dummyBadge}</Badge></span> : null}
          </FleetPushButton>
        );
      })}
    </div>
  );
}

/** A selected area's counts: In the field, the four states and the devices past due */
function AreaCounts({ area, t, nf }: { area: FleetArea; t: Copy["fleet"]; nf: Intl.NumberFormat }) {
  const rows: [string, number, FleetState | null][] = [
    [t.tile_in_field, area.inField, null], [t.tile_ready, area.ready, "ready"], [t.tile_needs_attention, area.needsAttention, "needs_attention"],
    [t.tile_no_connection, area.noConnection, "no_connection"], [t.tile_not_monitored, area.notMonitored, "not_monitored"], [t.tile_past_due, area.pastDue, null],
  ];
  return (
    <dl className="mb-4 grid grid-cols-2 gap-x-4 gap-y-1 text-small" data-testid="fleet-area-counts">
      {rows.map(([label, n, s]) => (
        <div key={label} className="flex items-center justify-between gap-2 border-b border-p4a-border py-1">
          <dt className="flex items-center gap-2 text-p4a-body">
            {s ? <span className={`inline-block h-3 w-3 shrink-0 rounded-full ${FLEET_STATE_SWATCH[s]}`} aria-hidden="true" /> : null}
            {label}
          </dt>
          <dd className="tabular font-semibold text-p4a-body">{nf.format(n)}</dd>
        </div>
      ))}
    </dl>
  );
}

/** A device's monitoring state as a badge: its colour (D8) next to its label, never the colour alone */
function StateBadge({ state, t }: { state: FleetState | null; t: Copy["fleet"] }) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-button bg-p4a-neutral-surface px-2 py-0.5 text-caption font-semibold text-p4a-body"
      data-testid="fleet-row-state" data-state={state ?? "none"}>
      {state ? <span className={`inline-block h-2.5 w-2.5 shrink-0 rounded-full ${FLEET_STATE_SWATCH[state]}`} aria-hidden="true" /> : null}
      {state ? t[`state_${state}`] : t.state_none}
    </span>
  );
}

/**
 * The list's page: 50 devices, a row selects its area; the count and the pager. leadWithWhy (the devices that need
 * attention, and Devices past due's list): a device listed only for its items past due shows that as its badge, its
 * monitoring state as text (E5). The last contact: its date and time, "Not monitored" for a device not monitored, "—"
 * where there is none (E4: never "None")
 */
async function FleetList({ read, st, t, modelName, timeZone, locale, leadWithWhy }: {
  read: Promise<{ page: FleetRowsPage | null; error: unknown }>;
  st: FleetAddressState;
  t: Copy["fleet"];
  modelName: (key: string) => string;
  timeZone: string;
  locale: Principal["locale"];
  leadWithWhy: boolean;
}) {
  const { page, error } = await read;
  if (!page) throw error;
  // under CMA_DB_TRACE the request's whole cost, written after the streamed read (verify/round-trips.mjs reads the last)
  const dbTrace = requestDbTrace();
  const trace = dbTrace ? <meta name="cma-db" content={dbTrace} /> : null;
  const nf = new Intl.NumberFormat(locale);
  const pages = Math.max(1, Math.ceil(page.total / page.pageSize));
  if (page.rows.length === 0) return <>{trace}<p className="text-body text-p4a-muted" data-testid="fleet-list-empty">{t.noDevices}</p></>;
  const reasons = (r: FleetRow) => [r.reason && r.reason !== "items_past_due" ? t[`reason_${r.reason}`] : null, r.pastDueItems > 0 ? t.reason_items_past_due : null]
    .filter((x): x is string => x !== null).join(", ");
  return (
    <div data-testid="fleet-list">
      {trace}
      <p className="mb-2 text-caption text-p4a-grey">
        {t.listOf.replace("{shown}", nf.format(page.rows.length)).replace("{total}", nf.format(page.total))}
      </p>
      <ul className="flex flex-col">
        {page.rows.map((r) => {
          const stateText = r.state ? t[`state_${r.state}`] : t.state_none;
          // E5: listed only for its items past due (not for its monitoring state): that is its badge, the state its text
          const forPastDue = leadWithWhy && r.pastDueItems > 0 && r.state !== "needs_attention" && r.state !== "no_connection";
          // the meta line's text: the state for a device listed for its items past due (Not monitored stands in the last
          // contact's place already), the reasons otherwise
          const meta = forPastDue ? (r.state === "not_monitored" ? "" : stateText) : reasons(r);
          const body = (
            <>
              <span className="flex w-full flex-wrap items-baseline gap-x-2">
                <span className="tabular font-semibold text-p4a-body">{r.serial ?? "—"}</span>
                <span className="text-small text-p4a-muted">{modelName(r.model)}</span>
                <span className="ml-auto text-caption text-p4a-grey">{r.areaCode ? `${r.market} ${r.areaCode}` : r.market}</span>
              </span>
              <span className="mt-1 flex w-full flex-wrap items-center gap-x-2 gap-y-1 text-caption text-p4a-body">
                {forPastDue ? <span data-testid="fleet-row-past-due"><Badge tone="warning">{t.badge_items_past_due}</Badge></span> : <StateBadge state={r.state} t={t} />}
                {meta ? <span>{meta}</span> : null}
                <span className="ml-auto text-p4a-grey" data-testid="fleet-row-contact">
                  {r.state === "not_monitored" ? t.state_not_monitored
                    : `${t.col_contact}: ${r.lastContactAt ? fmtDateTimeShort(r.lastContactAt, timeZone, locale) : "—"}`}
                </span>
              </span>
            </>
          );
          return (
            <li key={r.deviceId} className="border-b border-p4a-border last:border-b-0">
              {r.areaId ? (
                <FleetPushButton href={fleetHref(fleetQueryOf({ ...st, areaId: r.areaId, page: 1 }))} testId="fleet-row" pressed={r.areaId === st.areaId}
                  label={t.rowArea.replace("{serial}", r.serial ?? "").replace("{state}", stateText).replace("{code}", r.areaCode ?? "")}
                  className="flex w-full flex-col items-start px-2 py-2 text-left hover:bg-p4a-bgblue/50">
                  {body}
                </FleetPushButton>
              ) : (
                <div role="group" className="flex w-full flex-col items-start px-2 py-2" data-testid="fleet-row"
                  aria-label={t.rowNoArea.replace("{serial}", r.serial ?? "").replace("{state}", stateText)}>
                  {body}
                </div>
              )}
            </li>
          );
        })}
      </ul>
      {pages > 1 ? (
        <nav className="mt-4 flex items-center justify-between gap-2 text-small" aria-label={t.pageOf.replace("{page}", String(page.page)).replace("{pages}", String(pages))}>
          {page.page > 1 ? (
            <FleetPushButton href={fleetHref(fleetQueryOf({ ...st, page: page.page - 1 }))} testId="fleet-previous"
              className="h-10 rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{t.previous}</FleetPushButton>
          ) : <span />}
          <span className="text-p4a-muted">{t.pageOf.replace("{page}", nf.format(page.page)).replace("{pages}", nf.format(pages))}</span>
          {page.page < pages ? (
            <FleetPushButton href={fleetHref(fleetQueryOf({ ...st, page: page.page + 1 }))} testId="fleet-next"
              className="h-10 rounded-button border border-p4a-deepblue bg-white px-4 font-semibold text-p4a-deepblue">{t.next}</FleetPushButton>
          ) : <span />}
        </nav>
      ) : null}
    </div>
  );
}

