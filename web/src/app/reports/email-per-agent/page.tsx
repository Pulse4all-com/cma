import { notFound } from "next/navigation";
import { EmailDateLine } from "@/components/EmailParts";
import { EmailFilters } from "@/components/EmailFilters";
import { EmailPerAgentTable } from "@/components/EmailPerAgentTable";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { EMAIL_PER_AGENT_PERMISSION, EMAIL_PER_PERSON_KEY, emailFilterQuery, parseEmailFilter } from "@/lib/email";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fillHint, MAX_REPORT_DAYS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Email per agent (Report, addition 0008t; brief N19-A part 1): the email figures per person for a period,
 * narrowed by market (K), inbox (I) and mailbox (B): the emails they sent, the conversations they replied to
 * first with the typical first reply in business time and the share within the target, and the conversations
 * they closed, each count with an inline bar against its column's largest. Sorted by name, never ranked. A row
 * opens (Enter or a click) to that person's sends per hour of the day. Owner ids without a person come last as
 * one row with how many they are, never which; then the total. There only while the tenant's reports.per_person
 * holds email (Yordi agreed for Pulse4all, README Decision log, 18 October 2026): otherwise the page is not
 * found, as its rail item and its route are absent; for people holding performance.team; the database checks
 * both again on every read. A tenant without email sees "No email connected", never 0.
 */
export default async function EmailPerAgentPage({ searchParams }: PageProps<"/reports/email-per-agent">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.emailPerAgent;
  if (!me.perPerson.includes(EMAIL_PER_PERSON_KEY)) notFound();

  if (!holdsAny(me, EMAIL_PER_AGENT_PERMISSION)) {
    return (
      <Shell copy={copy} me={me} active="email-per-agent">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={t.noPermissionTitle} body={t.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const { filter, problem } = parseEmailFilter(sp.market, sp.inbox, sp.account);
  const agents = await data().getEmailPerAgent(me, period, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const h = copy.hints;
  const values = { hours: h.officeHours, target: agents.replyTargetMinutes };
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("email")).map(([k, v]) => [k, fillHint(v, values, me.locale)]));

  return (
    <Shell copy={copy} me={me} active="email-per-agent" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/email-per-agent" range={range} period={period} today={today} copy={copy} keep={emailFilterQuery(filter)} />
        </div>
        {agents.email ? (
          <div className="mb-6">
            <EmailFilters pathname="/reports/email-per-agent" markets={agents.markets} inboxes={agents.inboxes} accounts={agents.accounts} filter={filter}
              query={periodQuery} copy={copy} />
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
          <Notice tone="warning">{copy.email.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex justify-end">
        <EmailDateLine from={period.from} to={period.to} market={filter.market} inbox={filter.inbox} account={filter.account}
          inboxes={agents.inboxes} accounts={agents.accounts} copy={copy} locale={me.locale} />
      </div>

      <Card>
        {!agents.email ? (
          <p className="text-body" data-testid="email-agents-not-connected">
            <NotConnected label={copy.reports.noEmail} hint={copy.reports.noEmailHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noEmailHint}</span>
          </p>
        ) : agents.rows.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.empty}</p>
        ) : (
          <>
            <EmailPerAgentTable rows={agents.rows} total={agents.total} hints={hints} copy={copy} locale={me.locale} />
            <p className="mt-4 text-caption text-p4a-grey">{t.keyboard}</p>
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
