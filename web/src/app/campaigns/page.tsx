import Link from "next/link";
import { DesignLink, JourneyStatusBadge, journeyMarket, prerequisitesCount } from "@/components/CampaignParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { resolve } from "../access";

/**
 * Campaign monitoring (addition 0008v, brief N19-A part 3): a card per journey of the tenant (cma.journeys(), the
 * archived ones left out), with its name, market, status, summary, how many prerequisites it lists and the design's
 * link when there is one. Every journey is a placeholder for a compliance or campaign monitor: no figures. Shown to
 * people holding reports.view or performance.team; the database checks again on every read. A tenant without
 * journeys says so in words.
 */
export default async function CampaignsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.campaigns;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="campaigns">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const journeys = await data().getJourneys(me);
  return (
    <Shell copy={copy} me={me} active="campaigns" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      {journeys.length === 0 ? (
        <Card>
          <p className="text-body" data-testid="journeys-empty">{t.empty}</p>
          <p className="mt-2 text-small text-p4a-muted">{t.emptyHint}</p>
        </Card>
      ) : (
        <ul className="grid grid-cols-1 gap-6 lg:grid-cols-2 xl:grid-cols-3" data-testid="journeys">
          {journeys.map((j) => (
            <li key={j.code} className="flex flex-col rounded-card border border-p4a-border bg-white p-6" data-testid="journey-card" data-code={j.code}>
              <div className="flex items-start justify-between gap-4">
                <h2 className="text-panel font-semibold text-p4a-heading">
                  <Link href={`/campaigns/${encodeURIComponent(j.code)}`} className="hover:underline">{j.name}</Link>
                </h2>
                <JourneyStatusBadge status={j.status} copy={copy} />
              </div>
              <p className="mt-1 text-caption text-p4a-grey">{journeyMarket(j, copy)}</p>
              {j.summary ? <p className="mt-4 text-body">{j.summary}</p> : null}
              <div className="mt-auto flex flex-wrap items-center justify-between gap-4 pt-6">
                <span className="text-small text-p4a-muted" data-testid="journey-prerequisites-count">{prerequisitesCount(j, copy)}</span>
                <DesignLink url={j.designUrl} copy={copy} />
              </div>
            </li>
          ))}
        </ul>
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
