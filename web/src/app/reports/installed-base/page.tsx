import { FlashOverview, flashState } from "@/components/FlashOverview";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { PageTitle } from "@/components/primitives";
import { overviewOf } from "@/lib/flash";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { resolve } from "../../access";

/**
 * Assets → Installed base (addition 0008zw, Martin, 5 November 2026): Reports → Flash's Installed base overview as a page
 * of the Assets group, rendered by the same code (components/FlashOverview) on the same read (getFlashView: the
 * overview's document and its first page of records in one transaction), now or as of a business date with a snapshot
 * (A), per market (K), with the same breakdowns, filters, records and files (X); Flash keeps its own Installed base
 * overview. The address keys are Flash's without o: market, asOf, sort, dir, page, measure and f_<dim>. Team figures
 * only, for reports.view or performance.team as Flash; the database checks again on every read. Serials, ids, statuses,
 * codes and the CRM's links only: never a name, email, phone or address.
 */
export default async function InstalledBasePage({ searchParams }: PageProps<"/reports/installed-base">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const title = copy.nav.installedBase;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="installed-base">
        <PageTitle>{title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const st = flashState(me, await searchParams, "installed_base");
  return <FlashOverview me={me} copy={copy} st={st} def={overviewOf("installed_base")!} path="/reports/installed-base" active="installed-base" title={title} />;
}
