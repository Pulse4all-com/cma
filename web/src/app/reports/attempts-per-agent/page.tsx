import { notFound } from "next/navigation";
import { AttemptFilters } from "@/components/AttemptFilters";
import { AttemptDateLine } from "@/components/AttemptParts";
import { AttemptsPerAgentTable } from "@/components/AttemptsPerAgentTable";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { ATTEMPTS_PER_AGENT_KEY, ATTEMPTS_PER_AGENT_PERMISSION, attemptFilterQuery, parseAttemptFilter } from "@/lib/attempts";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fmtCount, MAX_REPORT_DAYS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Attempts per agent (Report, addition 0008y, 19 October 2026): per deal owner, the deals they own in the period with
 * their attempts (by anyone), the attempts per deal, the share reached on the first attempt and the open deals never
 * attempted, narrowed by market (K), pipeline (P) and which deals count (S). Sorted by name, never ranked; owner ids
 * without a person last as one row with how many they are, never which; then the total. There only while the tenant's
 * reports.per_person holds attempts (off for Pulse4all until Yordi agrees, README Open decisions): otherwise the page is
 * not found, as its rail item and its route are absent; for people holding performance.team; the database checks both
 * again on every read.
 */
export default async function AttemptsPerAgentPage({ searchParams }: PageProps<"/reports/attempts-per-agent">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.attemptsPerAgent;
  if (!me.perPerson.includes(ATTEMPTS_PER_AGENT_KEY)) notFound();

  if (!holdsAny(me, ATTEMPTS_PER_AGENT_PERMISSION)) {
    return (
      <Shell copy={copy} me={me} active="attempts-per-agent">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const { filter, problem } = parseAttemptFilter(sp.market, sp.pipeline, sp.scope);
  const people = await data().getAttemptsPerAgent(me, period, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const h = copy.hints;
  const window = fmtCount(people.settings.preWindowMinutes, me.locale);
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("at")).map(([k, v]) => [k, v.replaceAll("{window}", window)]));
  const pipelineLabel = filter.pipeline ? people.pipelines.find((p) => p.key === filter.pipeline)?.label ?? filter.pipeline : null;

  return (
    <Shell copy={copy} me={me} active="attempts-per-agent" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-2 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      <p className="mb-6 max-w-3xl text-small text-p4a-muted">{copy.attempts.doubleNote}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/attempts-per-agent" range={range} period={period} today={today} copy={copy} keep={attemptFilterQuery(filter)} />
        </div>
        <div className="mb-6">
          <AttemptFilters pathname="/reports/attempts-per-agent" markets={people.markets} pipelines={people.pipelines} filter={filter} query={periodQuery} copy={copy} />
        </div>
      </div>

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}
      {problem ? (
        <div className="mb-6">
          <Notice tone="warning">{copy.attempts.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <AttemptDateLine from={period.from} to={period.to} market={filter.market} pipelineLabel={pipelineLabel} counted={filter.scope === "counted"}
          historyStart={people.historyStart} copy={copy} locale={me.locale} />
      </div>

      <Card>
        {people.total.deals === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
          <AttemptsPerAgentTable rows={people.rows} total={people.total} hints={hints} copy={copy} locale={me.locale} />
        )}
      </Card>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
