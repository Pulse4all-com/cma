import { CallsDateLine } from "@/components/CallsParts";
import { CallsFilters } from "@/components/CallsFilters";
import { CallsPerAgentTable } from "@/components/CallsPerAgentTable";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { DATA_QUALITY_PERMISSIONS, fillHint, filterQuery, MAX_REPORT_DAYS, parseCallsFilter, PER_AGENT_PERMISSION } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Calls per agent (Report, addition 0008j, brief B16; Aircall's User Activity view): the calls figures
 * per person for a period, narrowed by market (K) and line (N): answered inbound calls with their talk
 * time, outbound calls, the connected ones with their talk time, conversations, untagged conversations
 * and the first and last call's time of day, each figure with an inline bar against its column's
 * largest. Sorted by name, never ranked (README Decision log, 7 and 14 October 2026: per-person call
 * figures for performance.team, agreed by Yordi). A row opens (Enter or a click) to that person's
 * conversations per counted tag. The calls of telephony users not linked to a person come last as one
 * row with how many users that is, never who, with a link to Data quality; then the total. Shown to
 * people holding performance.team only, hidden from the rail for everyone else; the database checks
 * again on every read. A tenant without telephony sees "No telephony connected", never 0.
 */
export default async function CallsPerAgentPage({ searchParams }: PageProps<"/reports/calls-per-agent">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.callsPerAgent;

  if (!holdsAny(me, PER_AGENT_PERMISSION)) {
    return (
      <Shell copy={copy} me={me} active="calls-per-agent">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const { filter, problem } = parseCallsFilter(sp.market, sp.line);
  const [agents, tags] = await Promise.all([
    data().getCallsPerAgent(me, period, filter),
    data().getCallsPerAgentTags(me, period, filter),
  ]);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };

  return (
    <Shell copy={copy} me={me} active="calls-per-agent" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/calls-per-agent" range={range} period={period} today={today} copy={copy} keep={filterQuery(filter)} />
        </div>
        {agents.telephony ? (
          <div className="mb-6">
            <CallsFilters pathname="/reports/calls-per-agent" markets={agents.markets} lines={agents.lines} filter={filter} query={periodQuery} copy={copy} />
          </div>
        ) : null}
      </div>

      {invalid ? (
        <div className="mb-6">
          <Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice>
        </div>
      ) : null}
      {problem ? (
        <div className="mb-6">
          <Notice tone="warning">{copy.calls.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <CallsDateLine from={period.from} to={period.to} market={filter.market} line={filter.line} lines={agents.lines} copy={copy} locale={me.locale} />
      </div>

      <Card>
        {!agents.telephony ? (
          <p className="text-body" data-testid="agents-not-connected">
            <NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noTelephonyHint}</span>
          </p>
        ) : agents.rows.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.empty}</p>
        ) : (
          <>
            <CallsPerAgentTable rows={agents.rows} total={agents.total} tags={tags.rows} copy={copy} locale={me.locale}
              threshold={agents.connectedMinSeconds} dataQuality={holdsAny(me, DATA_QUALITY_PERMISSIONS)} />
            <p className="mt-4 text-caption text-p4a-grey">{t.keyboard}</p>
            <p className="mt-1 text-caption text-p4a-grey">{fillHint(copy.calls.connectedNote, { hours: "", threshold: agents.connectedMinSeconds }, me.locale)}</p>
          </>
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
