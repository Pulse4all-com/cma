import { CallsChart, CallsDateLine, CallsGroupSwitch, CallsLegend, CallsTile, DeltaLine, previousLabel, TagBars, TagTable } from "@/components/CallsParts";
import { CallsFilters } from "@/components/CallsFilters";
import { PeriodBar } from "@/components/PeriodBar";
import { NoReportPermission, NotConnected } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type CallsGroup } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  chartGroups, fillHint, filterQuery, fmtCount, fmtPct, fmtTalk, MAX_REPORT_DAYS, parseCallsFilter, parseCallsGroup, REPORT_PERMISSIONS, untaggedPct,
} from "@/lib/reports";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Calls (Report, addition 0008j, brief B16; Aircall's General Performance and Outbound views): every call
 * on counted lines for a period, by day, ISO week, market or line (G cycles), narrowed by market (K) and
 * line (N). Four tiles (calls, inbound, outbound, average talk time), each with its change against the
 * previous period in Muted text with an arrow (a volume's change is neither good nor bad), like for like:
 * while the period runs, against the same point in the previous one, and the label says which; the
 * calls per group as stacked bars, inbound Deep Blue and outbound Leaf Green (the series order of
 * docs/style/Pulse4all-Style.md 7.7); the outbound calls with the connected ones (talk time of at least
 * telephony.connected_min_seconds) and their talk time; and the tags following the grouping: the untagged
 * share, the whole period's tags as bars (top twelve and Other) and the groups by tags as a table with
 * counts and row shares. Talk time runs from the answer to the end, without ringing, so it differs from
 * the telephony system's duration on purpose (README Decision log, 14 October 2026). Shown to people
 * holding reports.view or performance.team; the database checks again on every read. A tenant without
 * telephony sees "No telephony connected", never 0. Counts, seconds, line and tag names only: no
 * number, no customer name, no call id, never the caller's hash. Every tile and header explains itself
 * in a hint, the threshold filled in from the tenant's settings.
 */
export default async function CallsPage({ searchParams }: PageProps<"/reports/calls">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.calls;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="calls">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: CallsGroup = parseCallsGroup(sp.group) ?? "day";
  const { filter, problem } = parseCallsFilter(sp.market, sp.line);
  const [overview, tagUse] = await Promise.all([
    data().getCallsOverview(me, period, group, filter),
    data().getCallsTagUse(me, period, group, filter),
  ]);
  const periodQuery: Record<string, string> =
    range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const total = overview.total;
  const previous = overview.previous;
  const prevLabel = previousLabel(overview.previousFrom, overview.previousTo, overview.previousPartial, copy, me.locale);

  const h = copy.hints;
  const fill = (text: string) => fillHint(text, { hours: h.officeHours, threshold: overview.connectedMinSeconds }, me.locale);
  const info = (label: string, text: string) => ({ about: h.about.replace("{label}", label), text: fill(text) });
  const n = (x: number) => fmtCount(x, me.locale);
  const delta = (current: number | null, prev: number | null) =>
    <DeltaLine current={current} previous={prev} compared={prevLabel} copy={copy} locale={me.locale} />;
  const chartTitle: Record<CallsGroup, string> = { day: t.chartDay, week: t.chartWeek, market: t.chartMarket, line: t.chartLine };
  const tagTitle: Record<CallsGroup, string> = { day: t.tagTableDay, week: t.tagTableWeek, market: t.tagTableMarket, line: t.tagTableLine };

  return (
    <Shell copy={copy} me={me} active="calls" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="flex flex-wrap items-start justify-between gap-x-6">
        <div>
          <PeriodBar pathname="/reports/calls" range={range} period={period} today={today} copy={copy} keep={{ group, ...filterQuery(filter) }} />
        </div>
        {overview.telephony ? (
          <div className="mb-6">
            <CallsFilters pathname="/reports/calls" markets={overview.markets} lines={overview.lines} filter={filter}
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
        <CallsGroupSwitch group={group} query={{ ...periodQuery, ...filterQuery(filter) }} copy={copy} />
        <CallsDateLine from={period.from} to={period.to} market={filter.market} line={filter.line} lines={overview.lines} copy={copy} locale={me.locale} />
      </div>

      {!overview.telephony ? (
        <Card>
          <p className="text-body" data-testid="calls-not-connected">
            <NotConnected label={copy.reports.noTelephony} hint={copy.reports.noTelephonyHint} />
            <span className="ml-2 text-small text-p4a-muted">{copy.reports.noTelephonyHint}</span>
          </p>
        </Card>
      ) : (
        <div className="flex flex-col gap-6">
          <section className="grid grid-cols-4 gap-4" aria-label={t.title} data-testid="calls-tiles">
            <CallsTile testId="calls-total" label={t.calls} value={n(total.calls)} info={info(t.calls, h.callsTotal)}
              detail={t.callsDetail.replace("{conversations}", n(total.conversations))} delta={delta(total.calls, previous.calls)} />
            <CallsTile testId="calls-inbound" label={t.inbound} value={n(total.inbound)} info={info(t.inbound, h.callsInbound)}
              detail={t.inboundDetail.replace("{answered}", n(total.answeredInbound))} delta={delta(total.inbound, previous.inbound)} />
            <CallsTile testId="calls-outbound" label={t.outbound} value={n(total.outbound)} info={info(t.outbound, h.callsOutbound)}
              detail={t.outboundDetail.replace("{connected}", n(total.connectedOutbound))} delta={delta(total.outbound, previous.outbound)} />
            <CallsTile testId="calls-avg-talk" label={t.avgTalk} value={fmtTalk(total.talkAvgSeconds, me.locale)} info={info(t.avgTalk, h.callsAvgTalk)}
              detail={t.avgTalkDetail.replace("{total}", fmtTalk(total.talkSeconds, me.locale))} delta={delta(total.talkAvgSeconds, previous.talkAvgSeconds)} />
          </section>

          <Card title={chartTitle[group]}>
            {overview.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
              <>
                <CallsLegend copy={copy} />
                <CallsChart rows={chartGroups(overview.rows, group, period.from, period.to, today)} group={group} copy={copy} locale={me.locale} />
              </>
            )}
          </Card>

          <Card title={t.outboundTitle}>
            <div className="grid grid-cols-3 gap-4" data-testid="calls-outbound-tiles">
              <CallsTile testId="outbound-connected" label={t.connected} value={n(total.connectedOutbound)} info={info(t.connected, h.callsConnected)}
                detail={fill(t.connectedNote)} />
              <CallsTile testId="outbound-connected-pct" label={t.connectedPct} value={fmtPct(total.connectedPct, me.locale)} info={info(t.connectedPct, h.callsConnectedPct)}
                detail={t.connectedPctDetail.replace("{outbound}", n(total.outbound))} />
              <CallsTile testId="outbound-talk" label={t.outboundTalk} value={fmtTalk(total.outboundTalkSeconds, me.locale)} info={info(t.outboundTalk, h.callsOutboundTalk)}
                detail={t.outboundTalkDetail.replace("{avg}", fmtTalk(total.outboundTalkAvgSeconds, me.locale))} />
            </div>
          </Card>

          <Card title={t.tagsTitle}>
            {total.conversations === 0 ? <p className="text-body text-p4a-muted">{t.noConversations}</p> : (
              <div className="flex flex-col gap-6">
                <div className="grid grid-cols-4 gap-4">
                  <CallsTile testId="calls-untagged" label={t.untagged} value={fmtPct(untaggedPct(total), me.locale)} info={info(t.untagged, h.callsUntaggedPct)}
                    detail={t.untaggedDetail.replace("{untagged}", n(total.untaggedConversations)).replace("{conversations}", n(total.conversations))} />
                </div>
                <section aria-labelledby="tag-bars-title">
                  <h3 id="tag-bars-title" className="mb-3 text-body font-semibold text-p4a-heading">{t.tagBarsTitle}</h3>
                  <TagBars rows={tagUse.rows} conversations={total.conversations} copy={copy} locale={me.locale} />
                </section>
                <section aria-labelledby="tag-table-title">
                  <h3 id="tag-table-title" className="mb-3 text-body font-semibold text-p4a-heading">{tagTitle[group]}</h3>
                  <TagTable rows={tagUse.rows} groups={overview.rows} total={total} group={group} copy={copy} locale={me.locale} />
                </section>
                <p className="text-caption text-p4a-grey">{t.tagNote}</p>
              </div>
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
