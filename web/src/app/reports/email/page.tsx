import { CallsTile, DeltaLine, previousLabel } from "@/components/CallsParts";
import { EmailFilters } from "@/components/EmailFilters";
import {
  EmailDateLine, EmailFiguresTable, EmailGroupSwitch, NotRespondingTable, ReceivedColumns, SentColumns, WaitingTable,
} from "@/components/EmailParts";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type EmailGroup } from "@/lib/data";
import { emailFilterQuery, parseEmailFilter, parseEmailGroup, withinShare } from "@/lib/email";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import { fillHint, fmtCount, fmtShare, fmtTalk, MAX_REPORT_DAYS, REPORT_PERMISSIONS } from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { metricsMore } from "@/lib/metrics";
import { resolve } from "../../access";

/**
 * Email (Report, addition 0008t; brief N19-A part 1): every counted email of a period, per day or ISO week (G),
 * narrowed by market (K), inbox (I) and mailbox (B). Five tiles: received (the logged replies counted apart),
 * sent by agents (automated, bounced and failed apart), conversations opened (and closed), the first reply in
 * business time with the share within the tenant's target, and the time to close; the volumes with their change
 * against the previous period in Muted text with an arrow, like for like (as Calls: while the period runs,
 * against the same point in the previous one; before the tenant's email history "No history to compare yet").
 * Then the received messages per day or week as columns per inbox and per mailbox, the sends of agents and
 * automations, the first reply per inbox, the figures per mailbox, category and market, the conversations
 * waiting now and the lead deals not responding (each capped by follow_up.list_rows). Shown to people holding
 * reports.view or performance.team; the database checks again on every read. A tenant without email sees "No
 * email connected", never 0. Ids, codes, counts and times only. Every tile and header explains itself in a hint
 * with the tenant's values filled in.
 */
export default async function EmailPage({ searchParams }: PageProps<"/reports/email">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.email;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="email">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: EmailGroup = parseEmailGroup(sp.group) ?? "day";
  const { filter, problem } = parseEmailFilter(sp.market, sp.inbox, sp.account);
  const report = await data().getEmailReport(me, period, group, filter);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const prevLabel = previousLabel(report.previousFrom, report.previousTo, report.previousPartial, copy, me.locale);

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const values = { hours: h.officeHours, target: report.replyTargetMinutes, days: report.noResponseDays };
  const fill = (text: string) => fillHint(text, values, me.locale);
  // key: the figure's entry in the metric catalog; the link shows only to a holder of tenant.configure
  const info = (label: string, text: string, key?: string) =>
    ({ about: h.about.replace("{label}", label), text: fill(text), more: key ? metricsMore(me.permissions, key, h.howComputed) : undefined });
  const hints: Record<string, string> = Object.fromEntries(Object.entries(h).filter(([k]) => k.startsWith("email")).map(([k, v]) => [k, fill(v)]));
  const delta = (current: number, previous: number) =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={report.previousFrom} historyStart={report.historyStart}
      copy={copy} locale={me.locale} historyText={t.historyStarts} />;
  const total = report.total;
  const share = withinShare(total);
  const perGroup = group === "day" ? t.perDay : t.perWeek;

  return (
    <Shell copy={copy} me={me} active="email" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/email" range={range} period={period} today={today} copy={copy} keep={{ group, ...emailFilterQuery(filter) }} />
        </div>
        {report.email ? (
          <div className="mb-6">
            <EmailFilters pathname="/reports/email" markets={report.markets} inboxes={report.inboxes} accounts={report.accounts} filter={filter}
              query={{ ...periodQuery, group }} copy={copy} />
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
          <Notice tone="warning">{t.filterIgnored}</Notice>
        </div>
      ) : null}

      <div className="mb-6 flex items-end justify-between gap-4">
        <EmailGroupSwitch group={group} query={{ ...periodQuery, ...emailFilterQuery(filter) }} copy={copy} />
        <EmailDateLine from={period.from} to={period.to} market={filter.market} inbox={filter.inbox} account={filter.account}
          inboxes={report.inboxes} accounts={report.accounts} copy={copy} locale={me.locale} />
      </div>

      {!report.email ? (
        <Card>
          <p className="text-body" data-testid="email-not-connected">
            <NotConnected label={copy.reports.noEmail} hint={copy.reports.noEmailHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noEmailHint}</span>
          </p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section className="grid grid-cols-5 gap-4" aria-label={t.title} data-testid="email-tiles">
            <CallsTile testId="email-received" label={t.received} value={n(total.received)} info={info(t.received, h.emailReceived, "email.received")}
              detail={t.receivedDetail.replace("{logged}", n(total.loggedReplies))} delta={delta(total.received, report.previous.received)} />
            <CallsTile testId="email-sent" label={t.sent} value={n(total.sentAgent)} info={info(t.sent, h.emailSent, "email.sent_agent")}
              detail={t.sentDetail.replace("{automated}", n(total.sentAutomated)).replace("{failed}", n(total.bouncedFailed))}
              delta={delta(total.sentAgent, report.previous.sentAgent)} />
            <CallsTile testId="email-opened" label={t.opened} value={n(total.threadsOpened)} info={info(t.opened, h.emailOpened, "email.conversations_opened")}
              detail={t.openedDetail.replace("{closed}", n(total.threadsClosed))} delta={delta(total.threadsOpened, report.previous.threadsOpened)} />
            <CallsTile testId="email-first-reply" label={t.firstReply} value={fmtTalk(total.replyMedianBusinessSeconds, me.locale)} info={info(t.firstReply, h.emailFirstReply, "email.first_reply_median_business")}
              detail={total.replied === 0 ? t.firstReplyNone : total.targetKnown === 0 ? t.firstReplyNoHours.replace("{n}", n(total.noHours))
                : t.firstReplyDetail.replace("{pct}", fmtShare(share, me.locale)).replace("{target}", n(report.replyTargetMinutes))} />
            <CallsTile testId="email-to-close" label={t.toClose} value={fmtTalk(total.closeMedianBusinessSeconds, me.locale)} info={info(t.toClose, h.emailToClose, "email.time_to_close_median_business")}
              detail={t.toCloseDetail.replace("{elapsed}", fmtTalk(total.closeMedianSeconds, me.locale))} />
          </section>

          <Card title={`${t.receivedInbox}, ${perGroup}`}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{fill(h.emailChartInbox)}</p>
            {total.received === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <ReceivedColumns rows={report.receivedByInbox} group={group} from={period.from} to={period.to} last={today} split="inbox" copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={`${t.receivedAccount}, ${perGroup}`}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{fill(h.emailChartAccount)}</p>
            {total.received === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <ReceivedColumns rows={report.receivedByAccount} group={group} from={period.from} to={period.to} last={today} split="account" copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={`${t.sentChart}, ${perGroup}`}>
            <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{fill(h.emailChartSent)}</p>
            {total.sentAgent + total.sentAutomated === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <SentColumns rows={report.rows} group={group} from={period.from} to={period.to} last={today} copy={copy} locale={me.locale} />
            )}
          </Card>

          <Card title={t.byInbox}>
            {report.byInbox.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <EmailFiguresTable rows={report.byInbox} dimension="inbox" testId="email-by-inbox" title={t.byInbox} hints={hints} copy={copy} locale={me.locale}
                columns={["received", "threadsOpened", "replied", "medianReply", "medianElapsed", "within", "noHours", "threadsClosed", "medianClose"]} />
            )}
          </Card>

          <Card title={t.byAccount}>
            {report.byAccount.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <EmailFiguresTable rows={report.byAccount} dimension="account" testId="email-by-account" title={t.byAccount} hints={hints} copy={copy} locale={me.locale}
                columns={["received", "sentAgent", "sentAutomated", "threadsOpened", "replied", "medianReply", "within"]} />
            )}
          </Card>

          <div className="grid grid-cols-1 gap-6 min-[1800px]:grid-cols-2">
            <Card title={t.byCategory}>
              {report.byCategory.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <EmailFiguresTable rows={report.byCategory} dimension="category" testId="email-by-category" title={t.byCategory} hints={hints} copy={copy} locale={me.locale}
                  columns={["received", "loggedReplies", "sentAgent", "threadsOpened", "medianReply"]} />
              )}
            </Card>
            <Card title={t.byMarket}>
              {report.byMarket.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
                <EmailFiguresTable rows={report.byMarket} dimension="market" testId="email-by-market" title={t.byMarket} hints={hints} copy={copy} locale={me.locale}
                  columns={["received", "loggedReplies", "sentAgent", "threadsOpened", "medianReply"]} />
              )}
            </Card>
          </div>

          <Card title={t.waitingTitle}>
            <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
              <p className="max-w-3xl text-small text-p4a-muted">{t.waitingIntro}</p>
              {report.waiting.total > 0 ? (
                <p className="text-caption text-p4a-grey" data-testid="email-waiting-count">
                  {t.showing.replace("{shown}", n(report.waiting.rows.length)).replace("{total}", n(report.waiting.total))}
                </p>
              ) : null}
            </div>
            {report.waiting.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.waitingEmpty}</p> : (
              <WaitingTable rows={report.waiting.rows} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
            )}
          </Card>

          <Card title={t.notRespondingTitle}>
            <div className="-mt-2 mb-4 flex flex-wrap items-baseline justify-between gap-4">
              <p className="max-w-3xl text-small text-p4a-muted">{t.notRespondingIntro.replace("{days}", n(report.noResponseDays))}</p>
              {report.notResponding.total > 0 ? (
                <p className="text-caption text-p4a-grey" data-testid="email-not-responding-count">
                  {t.showing.replace("{shown}", n(report.notResponding.rows.length)).replace("{total}", n(report.notResponding.total))}
                </p>
              ) : null}
            </div>
            {report.notResponding.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.notRespondingEmpty}</p> : (
              <NotRespondingTable rows={report.notResponding.rows} hints={hints} copy={copy} locale={me.locale} timeZone={me.timeZone} />
            )}
          </Card>
        </div>
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
