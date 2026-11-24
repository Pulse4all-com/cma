import Link from "next/link";
import type { Route } from "next";
import { DeltaLine, previousLabel } from "@/components/CallsParts";
import { LinkPending } from "@/components/PendingMark";
import { PeriodBar } from "@/components/PeriodBar";
import { GroupSwitch, NoReportPermission } from "@/components/ReportParts";
import { Shell } from "@/components/Shell";
import { MarketButtons, SpeedDealRows, SpeedRefresh, type DealLine } from "@/components/SpeedToLeadClient";
import { GroupTable, MarketCard, SpeedTile, speedGroupLabel, TrendCard, type Info } from "@/components/SpeedToLeadParts";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { fmtAttempts } from "@/lib/attempts";
import { data, dataIsMock, type SpeedToLeadDeal, type SpeedToLeadGroup } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolvePeriod } from "@/lib/period";
import {
  fillHint, fmtBusinessMinutes, fmtCount, fmtPct, goalTone, MAX_REPORT_DAYS, parseCallsFilter, parseGroup, parseSpeedView, REPORT_PERMISSIONS,
  SPEED_DEALS_PAGE, speedTimeline, summaryTotals,
} from "@/lib/reports";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Speed to lead (Report, B11; the cockpit since addition 0009zr, brief B40b, mockup approved 24 November 2026): how fast
 * new lead deals get their first Attempt (an outbound call on the phone system linked to the deal or its contacts), in
 * office time of the deal's market, and how they are followed up after it. One read (cma.speed_to_lead_page) gives the
 * whole page: six tiles with their change against the previous period of the same length (within target and before the
 * cutoff coloured against the tenant's goals when set), the markets (two stacked bars each; a row sets the market
 * filter, as the buttons and K do), the trend per day (per week over 31 days) with the goals dashed and the weekends
 * shaded, the Group by table (G: day, market, agent, pipeline) and the deals, Not called yet or Called, 50 a page, each
 * with its attempts on a timeline of its first 1.5 working days and opened in full with Show attempts. While the period
 * reaches today the page reads itself again every 60 seconds through its own route, paused while the tab is hidden.
 * Shown to people holding reports.view or performance.team; the database checks again on every read. Ids, codes, counts,
 * times, people's names and links only: no customer name, email, phone number or recording, and a tag by its meaning.
 */
export default async function SpeedToLeadPage({ searchParams }: PageProps<"/reports/speed-to-lead">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.speedToLead;

  if (!holdsAny(me, REPORT_PERMISSIONS)) {
    return (
      <Shell copy={copy} me={me} active="speed-to-lead">
        <PageTitle>{t.title}</PageTitle>
        <NoReportPermission title={copy.reports.noPermissionTitle} body={copy.reports.noPermissionBody} />
      </Shell>
    );
  }

  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const { range, period, invalid } = resolvePeriod(sp, today, MAX_REPORT_DAYS);
  const group: SpeedToLeadGroup = parseGroup(sp.group) ?? "day";
  const view = parseSpeedView(sp.view) ?? "not_called";
  const { filter, problem } = parseCallsFilter(sp.market, null);
  const market = filter.market;
  const pageNo = typeof sp.page === "string" && /^[1-9][0-9]{0,3}$/.test(sp.page) ? Number(sp.page) : 1;
  const page = await data().getSpeedToLeadPage(me, period, market, group, view, (pageNo - 1) * SPEED_DEALS_PAGE);
  const f = page.figures;
  const s = f.settings;
  const live = period.to >= today;

  // the page's address with one part changed, the rest kept
  const periodQuery: Record<string, string> = range === "custom" && !invalid ? { range, from: period.from, to: period.to } : { range };
  const base: Record<string, string> = { ...periodQuery, group, view, ...(market ? { market } : {}) };
  const href = (change: Record<string, string | null>) => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries({ ...base, ...change })) if (v) q.set(k, v);
    return `/reports/speed-to-lead?${q.toString()}`;
  };
  const marketHref = (m: string) => href({ market: m || null, page: null });

  const h = copy.hints;
  const n = (x: number) => fmtCount(x, me.locale);
  const fill = (text: string) => fillHint(text, { hours: h.officeHours, target: s.targetMinutes, cutoff: s.nextDayCutoff }, me.locale);
  const info = (label: string, text: string): Info => ({ about: h.about.replace("{label}", label), text: fill(text) });
  const cutoff = s.nextDayCutoff || "–";
  const beforeLabel = t.beforeNoon.replace("{time}", cutoff);
  const prevLabel = previousLabel(f.previousFrom, f.previousTo, f.previousUntil !== null, copy, me.locale);
  const delta = (current: number | null, previous: number | null, better?: "up" | "down") =>
    <DeltaLine current={current} previous={previous} compared={prevLabel} previousFrom={f.previousFrom} historyStart={null}
      copy={copy} locale={me.locale} better={better} />;
  const minutes = (seconds: number | null) => fmtBusinessMinutes(seconds === null ? null : Math.floor(seconds / 60), me.locale);
  // the goal in words beside its colour: met or below it
  const goalText = (pct: number | null, goal: number | null) => {
    const tone = goalTone(pct, goal);
    if (goal === null) return "";
    const g = fmtPct(goal, me.locale);
    return ` · ${tone === "met" ? t.goalMet.replace("{pct}", g) : tone === "below" ? t.goalBelow.replace("{pct}", g) : t.goal.replace("{pct}", g)}`;
  };
  const cur = f.current;
  const prev = f.previous;
  const unknownMarket = copy.reports.unknownMarket;

  // the deals list's rows, every cell in words here, so the client part takes no catalog
  const yesNo = (x: boolean) => (x ? t.yes : t.no);
  const meaning = (k: string) => (copy.configSources as Record<string, string>)[`meaning_${k}`] ?? k;
  const dealLine = (d: SpeedToLeadDeal): DealLine => {
    const tl = speedTimeline(d, s.targetMinutes === null ? null : s.targetMinutes * 60);
    const called = d.status === "called";
    // no business time: the market is unknown, so it has no office hours to count
    const speed = d.businessSeconds === null ? t.noBusinessHours
      : called ? minutes(d.businessSeconds) : t.waitingFor.replace("{time}", minutes(d.businessSeconds));
    return {
      id: d.dealId, sourceId: d.dealSourceId, recordUrl: d.recordUrl, recordLabel: t.openRecord.replace("{id}", d.dealSourceId),
      market: d.market === "unknown" ? unknownMarket : d.market,
      owner: d.ownerName ?? t.noOwner, ownerMuted: d.ownerName === null,
      created: `${fmtDate(dateKeyInZone(d.createdAt, me.timeZone), me.locale, "compact")} ${fmtTime(d.createdAt, me.timeZone, me.locale)}`,
      attempts: n(d.attemptsSoFar), speed,
      speedTone: d.withinTarget === true ? "good" : d.withinTarget === false ? "bad" : "muted",
      stale: d.stale ? t.staleNote.replace("{n}", n(s.staleBusinessDays)) : null,
      timeline: tl === null ? null : {
        label: t.timelineLabel.replace("{id}", d.dealSourceId), target: tl.target, cutoff: tl.cutoff, waiting: tl.waiting, beyond: tl.beyond,
        dots: tl.dots.map((x) => {
          const a = d.attempts.find((y) => y.n === x.n)!;
          const kind = x.kind === "conversation" ? t.dotConversation : x.kind === "connected" ? t.dotConnected : t.dotNotConnected;
          return { ...x, title: `${x.n} · ${fmtTime(a.startedAt, me.timeZone, me.locale)} · ${kind}` };
        }),
      },
      lines: d.attempts.map((a) => ({
        n: n(a.n),
        start: `${fmtDate(dateKeyInZone(a.startedAt, me.timeZone), me.locale, "compact")} ${fmtTime(a.startedAt, me.timeZone, me.locale)}`,
        after: minutes(a.businessSeconds), connected: yesNo(a.connected),
        talk: a.talkSeconds === null ? "–" : `${Math.floor(a.talkSeconds / 60)}:${String(a.talkSeconds % 60).padStart(2, "0")}`,
        conversation: yesNo(a.conversation), tag: a.tagMeanings.length === 0 ? "–" : a.tagMeanings.map(meaning).join(", "),
        agent: a.agentName ?? copy.speedToLead.notMapped,
      })),
      firstOf: d.attemptsSoFar > d.attempts.length ? t.firstOf.replace("{shown}", n(d.attempts.length)).replace("{n}", n(d.attemptsSoFar)) : null,
    };
  };

  const groupHint: Record<SpeedToLeadGroup, string> = { day: h.day, week: h.day, market: h.market, agent: h.agent, pipeline: h.pipeline };
  const summaryHeaders = [
    { label: t[group], info: info(t[group], groupHint[group]) },
    { label: t.deals, info: info(t.deals, h.deals), right: true },
    { label: t.called, info: info(t.called, h.called), right: true },
    { label: t.median, info: info(t.median, h.median), right: true },
    { label: t.withinTarget, info: info(t.withinTarget, h.withinTarget), right: true },
    { label: beforeLabel, info: info(beforeLabel, h.beforeNoon), right: true },
    { label: t.notCalledYet, info: info(t.notCalledYet, h.notCalledYet), right: true },
    { label: t.closedBeforeFirstCall, info: info(t.closedBeforeFirstCall, h.closedBeforeFirstCall), right: true },
    { label: t.attemptsPerDeal, info: info(t.attemptsPerDeal, h.stlTileAttempts), right: true },
    { label: t.withConversation, info: info(t.withConversation, h.stlConversation), right: true },
  ];
  const marketHeaders = [
    { label: copy.reports.market, info: info(copy.reports.market, h.market) },
    { label: t.deals, info: info(t.deals, h.deals), right: true },
    { label: t.shareKnown, info: info(t.shareKnown, h.stlBars) },
    { label: t.median, info: info(t.median, h.median), right: true },
    { label: t.notCalledYet, info: info(t.notCalledYet, h.notCalledYet), right: true },
    { label: t.closedBeforeFirstCall, info: info(t.closedBeforeFirstCall, h.closedBeforeFirstCall), right: true },
    { label: t.attemptsPerDeal, info: info(t.attemptsPerDeal, h.stlTileAttempts), right: true },
    { label: t.withConversation, info: info(t.withConversation, h.stlConversation), right: true },
  ];
  const dh = (label: string, text: string, className?: string) => ({ label, about: h.about.replace("{label}", label), hint: fill(text), className });
  const dealHeaders = [
    dh(t.deal, h.deal), dh(copy.reports.market, h.market), dh(t.owner, h.stlOwner), dh(t.created, h.created),
    // Speed to lead is creation to the first attempt: the Not called yet view shows the wait instead, under its own name
    dh(t.attempts, h.stlAttempts, "text-right"),
    view === "called" ? dh(t.speedOrWaiting, h.stlSpeed, "text-right") : dh(t.waiting, h.waiting, "text-right"),
    dh(t.timeline, h.stlTimeline),
  ];
  const attemptHeaders = [
    dh(t.attemptNumber, h.stlAttemptNumber), dh(t.attemptStart, h.stlAttemptStart), dh(t.attemptAfter, h.stlAttemptAfter),
    dh(t.attemptConnected, h.stlAttemptConnected), dh(t.attemptTalk, h.stlAttemptTalk), dh(t.attemptConversation, h.stlAttemptConversation),
    dh(t.attemptTag, h.stlAttemptTag), dh(t.attemptAgent, h.stlAttemptAgent),
  ];
  const deals = page.deals;
  // a page past the last (a refresh moved deals between the views) holds no row to count from: the view's count is the figures'
  const total = deals.rows.length > 0 ? deals.total : view === "called" ? cur.called : cur.openNotCalled;
  const pages = Math.max(1, Math.ceil(total / SPEED_DEALS_PAGE));
  const groupWords = { notMapped: t.notMapped, noAttempt: t.noAttempt, unknownMarket, unknownPipeline: t.unknownPipeline };
  const tabs = [
    { view: "not_called", label: t.tabNotCalled.replace("{n}", n(cur.openNotCalled)) },
    { view: "called", label: t.tabCalled.replace("{n}", n(cur.called)) },
  ] as const;

  return (
    <Shell copy={copy} me={me} active="speed-to-lead" wide>
      <PageTitle aside={live ? (
        <span className="inline-flex items-center gap-2 text-small text-p4a-muted" data-testid="speed-live">
          <span aria-hidden="true" className="inline-block h-2 w-2 rounded-full bg-p4a-green" />{t.live}
        </span>
      ) : undefined}>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      {live ? <SpeedRefresh /> : null}

      <PeriodBar pathname="/reports/speed-to-lead" range={range} period={period} today={today} copy={copy}
        keep={{ group, view, ...(market ? { market } : {}) }} />

      {invalid ? (
        <div className="mb-6"><Notice tone="warning">{invalid === "length" ? copy.reports.tooLong : copy.myHours.invalidRange}</Notice></div>
      ) : null}
      {problem ? (
        <div className="mb-6"><Notice tone="warning">{copy.attempts.filterIgnored}</Notice></div>
      ) : null}

      <div className="mb-6 flex flex-wrap items-center justify-between gap-4">
        <MarketButtons markets={page.markets.map((m) => m.groupKey)} market={market ?? ""}
          hrefs={Object.fromEntries(["", ...page.markets.map((m) => m.groupKey)].map((m) => [m, marketHref(m)]))}
          words={{ label: t.marketFilter, all: t.allMarkets, unknown: t.unknownMarketShort }} />
        <p className="text-caption text-p4a-grey">
          {fmtDate(period.from, me.locale)}{period.from !== period.to ? ` – ${fmtDate(period.to, me.locale)}` : ""}
          {market ? ` · ${market === "unknown" ? unknownMarket : market}` : ""}
        </p>
      </div>

      <div className="flex flex-col gap-6">
        <section className="grid grid-cols-3 gap-4 xl:grid-cols-6" aria-label={t.title} data-testid="speed-tiles">
          <SpeedTile testId="speed-within" label={t.withinTarget} value={fmtPct(cur.withinTargetPct, me.locale)} info={info(t.withinTarget, h.stlTileWithinTarget)}
            detail={t.withinTargetDetail.replace("{target}", s.targetMinutes === null ? "–" : n(s.targetMinutes)) + goalText(cur.withinTargetPct, s.goalWithinTargetPct)}
            delta={delta(cur.withinTargetPct, prev.withinTargetPct, "up")} pct={cur.withinTargetPct} goal={s.goalWithinTargetPct} />
          <SpeedTile testId="speed-before" label={beforeLabel} value={fmtPct(cur.beforeNextNoonPct, me.locale)} info={info(beforeLabel, h.stlTileBeforeCutoff)}
            detail={t.beforeNoonDetail + goalText(cur.beforeNextNoonPct, s.goalBeforeCutoffPct)} delta={delta(cur.beforeNextNoonPct, prev.beforeNextNoonPct, "up")}
            pct={cur.beforeNextNoonPct} goal={s.goalBeforeCutoffPct} />
          <SpeedTile testId="speed-median" label={t.median} value={fmtBusinessMinutes(cur.medianBusinessMinutes, me.locale)} info={info(t.median, h.stlTileMedian)}
            detail={t.medianDetail} delta={delta(cur.medianBusinessMinutes, prev.medianBusinessMinutes, "down")} />
          <SpeedTile testId="speed-not-called" label={t.notCalledYet} value={n(cur.openNotCalled)} info={info(t.notCalledYet, h.stlTileNotCalled)}
            detail={cur.oldestWaitingBusinessSeconds === null ? t.noneWaiting : t.oldestWaiting.replace("{time}", minutes(cur.oldestWaitingBusinessSeconds))}
            delta={delta(cur.openNotCalled, prev.openNotCalled, "down")} />
          <SpeedTile testId="speed-closed" label={t.closedBeforeFirstCall} value={n(cur.closedBeforeFirstCall)} info={info(t.closedBeforeFirstCall, h.stlTileClosed)}
            detail={t.closedDetail} delta={delta(cur.closedBeforeFirstCall, prev.closedBeforeFirstCall, "down")} />
          <SpeedTile testId="speed-attempts" label={t.attemptsPerDeal} value={fmtAttempts(cur.attemptsMean, me.locale)} info={info(t.attemptsPerDeal, h.stlTileAttempts)}
            detail={t.attemptsDetail.replace("{median}", fmtAttempts(cur.attemptsMedian, me.locale))} delta={delta(cur.attemptsMean, prev.attemptsMean)} />
        </section>

        {page.markets.length > 0 ? (
          <MarketCard rows={page.markets} market={market ?? ""} hrefOf={marketHref} headers={marketHeaders} locale={me.locale}
            words={{
              title: t.perMarketTitle, legendLabel: t.perMarketTitle, note: t.perMarketNote, unknown: unknownMarket, filter: t.filterMarket,
              barsAria: t.barsAria.replace("{cutoff}", cutoff),
              legend: [
                { key: "within", label: t.legendWithinTarget, colour: 0, className: "bg-p4a-deepblue" },
                { key: "after", label: t.legendAfterTarget, colour: 0, className: "bg-p4a-lightblue" },
                { key: "before", label: t.legendBeforeCutoff.replace("{time}", cutoff), colour: 1, className: "bg-p4a-green" },
                { key: "late", label: t.legendAfterCutoff.replace("{time}", cutoff), colour: 1, className: "bg-p4a-border" },
              ],
            }} />
        ) : null}

        <TrendCard rows={page.trend} group={page.trendGroup} from={period.from} to={period.to} workingWeekdays={page.workingWeekdays} locale={me.locale}
          goals={{ withinTarget: s.goalWithinTargetPct, beforeCutoff: s.goalBeforeCutoffPct }}
          words={{
            title: page.trendGroup === "week" ? t.trendTitleWeek : t.trendTitleDay, within: t.withinTarget, before: beforeLabel,
            goalWithin: `${t.withinTarget}: ${t.goalLine.replace("{pct}", fmtPct(s.goalWithinTargetPct, me.locale))}`,
            goalBefore: `${beforeLabel}: ${t.goalLine.replace("{pct}", fmtPct(s.goalBeforeCutoffPct, me.locale))}`,
            weekend: t.noOfficeHours, share: t.trendShare, empty: t.trendEmpty, legendLabel: t.trendTitleDay,
          }} />

        <Card title={t.groupTable}>
          <div className="mb-4">
            <GroupSwitch group={group} query={{ ...periodQuery, view, ...(market ? { market } : {}) }} copy={copy} />
          </div>
          {page.groups.length === 0 ? <p className="text-body text-p4a-muted">{t.empty}</p> : (
            <>
              <GroupTable rows={page.groups} group={group} label={(x) => speedGroupLabel(x, group, groupWords, me.locale)} headers={summaryHeaders}
                totals={summaryTotals(page.groups)} totalLabel={copy.reports.total} totalNote={t.totalNote} locale={me.locale} />
              <p className="mt-4 max-w-3xl text-caption text-p4a-grey">
                {t.minutesNote.replace("{n}", s.targetMinutes !== null ? n(s.targetMinutes) : "–")}
              </p>
            </>
          )}
        </Card>

        <section className="rounded-card border border-p4a-border bg-white p-6" aria-labelledby="speed-deals-title" data-testid="speed-deals-card" data-view={view}>
          <div className="mb-4 flex flex-wrap items-center justify-between gap-4">
            <h2 id="speed-deals-title" className="text-h3 font-bold text-p4a-heading">{t.dealsTitle}</h2>
            <nav aria-label={t.dealsTabs} className="flex gap-2" data-testid="speed-tabs">
              {tabs.map((x) => (
                <Link key={x.view} href={href({ view: x.view, page: null }) as Route} scroll={false} aria-current={x.view === view ? "page" : undefined}
                  className={["relative inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
                    x.view === view ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue"].join(" ")}>
                  {x.label}<LinkPending />
                </Link>
              ))}
            </nav>
          </div>
          <ul className="mb-4 flex flex-wrap items-center gap-x-6 gap-y-2 text-small text-p4a-muted" aria-label={t.timeline}>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-3 w-3 rounded-full border-2 border-p4a-denim bg-white" />{t.dotNotConnected}</li>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-3 w-3 rounded-full border-2 border-p4a-denim bg-p4a-denim" />{t.dotConnected}</li>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-3 w-3 rounded-full border-2 border-p4a-green bg-p4a-green" />{t.dotConversation}</li>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-4 w-0.5 bg-p4a-grey" />{t.markTarget.replace("{target}", s.targetMinutes === null ? "–" : n(s.targetMinutes))}</li>
            <li className="flex items-center gap-2"><span aria-hidden="true" className="inline-block h-4 w-0.5 bg-p4a-inkt" />{t.markCutoff.replace("{time}", cutoff)}</li>
            <li>{t.timelineSpan}</li>
          </ul>
          {deals.rows.length === 0 ? <p className="text-body text-p4a-muted">{t.noDeals}</p> : (
            <SpeedDealRows rows={deals.rows.map(dealLine)} headers={dealHeaders} attemptHeaders={attemptHeaders}
              words={{ show: t.showAttempts, hide: t.hideAttempts, noPersonalData: t.noPersonalData, actions: t.dealsTitle, beyond: t.beyondSpan }} />
          )}
          {pages > 1 ? (
            <nav aria-label={t.pager} className="mt-4 flex items-center justify-end gap-4 text-small" data-testid="speed-pager">
              <span className="text-p4a-muted">
                {t.pageOf.replace("{from}", n(Math.min(total, deals.offset + 1))).replace("{to}", n(Math.min(total, deals.offset + SPEED_DEALS_PAGE))).replace("{n}", n(total))}
              </span>
              {pageNo > 1 ? <Link href={href({ page: String(pageNo - 1) }) as Route} scroll={false} className="relative pr-3 font-semibold text-p4a-deepblue">{t.previousPage}<LinkPending /></Link> : null}
              {pageNo < pages ? <Link href={href({ page: String(pageNo + 1) }) as Route} scroll={false} className="relative pr-3 font-semibold text-p4a-deepblue">{t.nextPage}<LinkPending /></Link> : null}
            </nav>
          ) : null}
        </section>
      </div>

      {dataIsMock ? (
        <div className="mt-6"><Notice tone="info">{copy.shell.testData}</Notice></div>
      ) : null}
    </Shell>
  );
}
