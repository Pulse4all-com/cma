import { notFound } from "next/navigation";
import { DesignLink, JourneyStatusBadge, journeyMarket, PLANNED, PlannedCard } from "@/components/CampaignParts";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, PageTitle } from "@/components/primitives";
import { data } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { REPORT_PERMISSIONS } from "@/lib/reports";
import { resolve } from "../../access";

/**
 * One journey of Campaign monitoring (addition 0008v, brief N19-A part 3): a Muted banner that says the monitor is
 * not built yet and nothing here is real data; the journey's market, status, summary and design link; the planned
 * layout as muted, dashed placeholders, each one line on what it will show (the customer drill-down locked); the
 * journey's prerequisites as a checklist, none ticked. No figures and no customer data. Breadcrumbs Campaigns › the
 * journey. An archived or unknown journey is not found; the permissions as the list's.
 */
export default async function JourneyPage({ params }: { params: Promise<{ code: string }> }) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.campaigns;
  const { code } = await params;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="campaigns">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const journey = (await data().getJourneys(me)).find((j) => j.code === code);
  if (!journey) notFound();

  return (
    <Shell copy={copy} me={me} active="campaigns" wide trail={[{ label: journey.name }]}>
      <PageTitle>{journey.name}</PageTitle>
      <p role="note" className="mb-6 rounded-button border-l-4 border-p4a-muted bg-p4a-neutral-surface px-4 py-3 text-body text-p4a-muted" data-testid="journey-banner">
        {t.banner}
      </p>

      <div className="mb-6 flex flex-wrap items-center gap-4">
        <JourneyStatusBadge status={journey.status} copy={copy} />
        <span className="text-small text-p4a-grey">{journeyMarket(journey, copy)}</span>
        <DesignLink url={journey.designUrl} copy={copy} />
      </div>
      {journey.summary ? <p className="mb-6 max-w-3xl text-body">{journey.summary}</p> : null}

      <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.plannedTitle}</h2>
      <div className="mb-6 grid grid-cols-1 gap-6 lg:grid-cols-2 xl:grid-cols-3" data-testid="journey-planned">
        {PLANNED.map((p) => <PlannedCard key={p} plan={p} copy={copy} />)}
      </div>

      <Card title={t.prerequisitesTitle}>
        <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.prerequisitesIntro}</p>
        {journey.prerequisites.length === 0 ? <p className="text-body text-p4a-muted">{t.noPrerequisites}</p> : (
          <ul className="flex flex-col gap-3" aria-label={t.prerequisitesTitle} data-testid="journey-prerequisites">
            {journey.prerequisites.map((line, i) => (
              <li key={i} className="flex items-start gap-3 text-body" data-testid="journey-prerequisite">
                <span aria-hidden="true" className="mt-0.5 inline-block h-4 w-4 shrink-0 rounded-sm border border-p4a-muted bg-white" />
                <span><span className="sr-only">{t.notDone}: </span>{line}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </Shell>
  );
}
