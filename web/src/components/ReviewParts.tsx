/**
 * Building blocks of Reports → Reviews (addition 0008ze, brief B18; KPI 3): the reviews per whole star, per market with
 * the previous period, the markets with their review-channel state, per day or week, per review channel, by link level
 * and by invite event. Server components, plain CSS; Pulse4all-Style 7.5 to 7.7 as Reports → Cancellations: horizontal
 * bars in Deep Blue, the reviews without a link or an invite event in the neutral hue, never a red stack; every header
 * with its hint. Team figures only, never a person's; counts, ratings, codes and channel names only, never a reviewer or
 * a review's text.
 */
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { FunnelGroup, ReviewFigures, ReviewMarketState, ReviewsReport } from "@/lib/data";
import { FUNNEL_BAR_CLASS, FUNNEL_NEUTRAL_CLASS } from "@/lib/funnel";
import { barShare, fmtCount } from "@/lib/reports";
import { fmtRating } from "@/lib/reviews";
import { fmtDate } from "@/lib/time";
import { BarList } from "./FunnelParts";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { Badge } from "./primitives";

const th = "h-10 px-2 py-1 align-bottom font-semibold";
const td = "h-10 whitespace-nowrap px-2 tabular text-right";
const row = "border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50";

function Scroll({ testId, label, children }: { testId: string; label: string; children: ReactNode }) {
  return (
    <div className="overflow-x-auto" data-testid={`${testId}-scroll`} role="region" aria-label={label} tabIndex={0}>
      <table className="w-full border-collapse text-body leading-table" data-testid={testId}>{children}</table>
    </div>
  );
}

const marketName = (m: string, copy: Copy) => (m === "unknown" ? copy.reports.unknownMarket : m);
type Col<T> = [string, string, (r: T) => string];

function Head<T>({ first, firstHint, cols, copy }: { first: string; firstHint: string; cols: Col<T>[]; copy: Copy }) {
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  return (
    <thead>
      <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
        <th className={th}><HintLabel label={first}>{hint(first, firstHint)}</HintLabel></th>
        {cols.map(([label, text]) => <th key={label} className={`${th} text-right`}><HintLabel label={label}>{hint(label, text)}</HintLabel></th>)}
      </tr>
    </thead>
  );
}

/** The figures' columns every table shares: reviews, average rating, negative reviews */
function figureCols(copy: Copy, hints: Record<string, string>, locale: Locale): Col<ReviewFigures>[] {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  return [[t.colReviews, hints.rvColReviews!, (f) => n(f.reviews)], [t.colAverage, hints.rvColAverage!, (f) => fmtRating(f.averageRating, locale)],
    [t.colNegative, hints.rvColNegative!, (f) => n(f.negative)]];
}

/** The reviews per whole star, 5 to 1, with the previous period's in the label's title */
export function ReviewDistribution({ rows, copy, locale }: { rows: ReviewsReport["distribution"]; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const largest = Math.max(0, ...rows.map((r) => r.reviews));
  return (
    <BarList testId="reviews-distribution" label={t.distributionCard} className={FUNNEL_BAR_CLASS}
      bars={[...rows].reverse().map((r) => ({ key: String(r.stars), label: t.stars.replace("{n}", String(r.stars)), share: barShare(r.reviews, largest), value: n(r.reviews),
        title: t.starsTitle.replace("{n}", String(r.stars)).replace("{reviews}", n(r.reviews)).replace("{previous}", n(r.previous)) }))} />
  );
}

/** The reviews per market with the previous period's reviews and average rating */
export function ReviewMarkets({ rows, hints, copy, locale }: { rows: ReviewsReport["byMarket"]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const cols: Col<ReviewsReport["byMarket"][number]>[] = [
    ...figureCols(copy, hints, locale).map(([a, b, f]): Col<ReviewsReport["byMarket"][number]> => [a, b, (r) => f(r.current)]),
    [t.colPreviousReviews, hints.rvColPreviousReviews!, (r) => n(r.previous.reviews)],
    [t.colPreviousAverage, hints.rvColPreviousAverage!, (r) => fmtRating(r.previous.averageRating, locale)],
  ];
  return (
    <Scroll testId="reviews-markets" label={t.marketCard}>
      <Head first={t.colMarket} firstHint={hints.rvColMarket!} cols={cols} copy={copy} />
      <tbody>
        {rows.map((r) => (
          <tr key={r.market} className={row}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{marketName(r.market, copy)}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

const STATE_TONE: Record<ReviewMarketState, "neutral" | "warning" | "success"> = { no_channel: "neutral", channel_no_reviews: "warning", has_reviews: "success" };

/** Every active market with its review channel's state (KPI 11, data first), whatever the filter */
export function ReviewMarketStates({ rows, hints, copy, locale }: { rows: ReviewsReport["marketStates"]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const states = t as unknown as Record<string, string>;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  return (
    <Scroll testId="reviews-market-states" label={t.statesCard}>
      <thead>
        <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
          <th className={th}><HintLabel label={t.colMarket}>{hint(t.colMarket, hints.rvColMarket!)}</HintLabel></th>
          <th className={th}><HintLabel label={t.colState}>{hint(t.colState, hints.rvColState!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colChannels}>{hint(t.colChannels, hints.rvColChannels!)}</HintLabel></th>
          <th className={`${th} text-right`}><HintLabel label={t.colAllReviews}>{hint(t.colAllReviews, hints.rvColAllReviews!)}</HintLabel></th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.market} className={row} data-state={r.state}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{r.market} <span className="font-normal text-p4a-muted">{r.name}</span></td>
            <td className="h-10 whitespace-nowrap px-2"><Badge tone={STATE_TONE[r.state]}>{states[`state_${r.state}`] ?? r.state}</Badge></td>
            <td className={td}>{n(r.channels)}</td>
            <td className={td}>{n(r.reviews)}</td>
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The reviews per day or week (every one of the period, empty ones too) */
export function ReviewPeriods({ rows, group, hints, copy, locale }: { rows: ReviewsReport["byPeriod"]; group: FunnelGroup; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const first = group === "week" ? copy.funnel.week : copy.funnel.day;
  const labelOf = (k: string) => (group === "week" ? copy.funnel.weekLabel.replace("{week}", fmtDate(k, locale, "short")) : fmtDate(k, locale, "compact"));
  const cols: Col<ReviewsReport["byPeriod"][number]>[] = [...figureCols(copy, hints, locale),
    [t.colLinked, hints.rvColLinked!, (f) => n(f.linkedOrder + f.linkedContact)]];
  return (
    <Scroll testId="reviews-periods" label={group === "week" ? t.periodCardWeek : t.periodCardDay}>
      <Head first={first} firstHint={hints.rvColPeriod!} cols={cols} copy={copy} />
      <tbody>
        {rows.map((r) => (
          <tr key={r.key} className={row}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{labelOf(r.key)}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The reviews per review channel (the platform's name), with its market and the previous period's reviews */
export function ReviewChannels({ rows, hints, copy, locale }: { rows: ReviewsReport["byChannel"]; hints: Record<string, string>; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const cols: Col<ReviewsReport["byChannel"][number]>[] = [
    [t.colMarket, hints.rvColMarket!, (r) => marketName(r.market, copy)],
    ...figureCols(copy, hints, locale).map(([a, b, f]): Col<ReviewsReport["byChannel"][number]> => [a, b, (r) => f(r.current)]),
    [t.colPreviousReviews, hints.rvColPreviousReviews!, (r) => n(r.previous.reviews)],
  ];
  return (
    <Scroll testId="reviews-channels" label={t.channelCard}>
      <Head first={t.colChannel} firstHint={hints.rvColChannel!} cols={cols} copy={copy} />
      <tbody>
        {rows.map((r) => (
          <tr key={r.channel} className={row}>
            <td className="h-10 whitespace-nowrap px-2 font-semibold">{r.name}</td>
            {cols.map(([label, , value]) => <td key={label} className={td}>{value(r)}</td>)}
          </tr>
        ))}
      </tbody>
    </Scroll>
  );
}

/** The reviews by link level: to an order, to a contact, none (in the neutral hue) */
export function ReviewLinkLevels({ rows, copy, locale }: { rows: ReviewsReport["linkLevels"]; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const words = t as unknown as Record<string, string>;
  const largest = Math.max(0, ...rows.map((r) => r.reviews));
  const bar = (r: ReviewsReport["linkLevels"][number]) => ({ key: r.level, label: words[`level_${r.level}`] ?? r.level, share: barShare(r.reviews, largest), value: n(r.reviews),
    title: t.previousTitle.replace("{label}", words[`level_${r.level}`] ?? r.level).replace("{reviews}", n(r.reviews)).replace("{previous}", n(r.previous)) });
  return (
    <div className="flex flex-col gap-4">
      <BarList testId="reviews-links" label={t.linkCard} className={FUNNEL_BAR_CLASS} bars={rows.filter((r) => r.level !== "none").map(bar)} />
      <BarList testId="reviews-unlinked" label={t.level_none} className={FUNNEL_NEUTRAL_CLASS} bars={rows.filter((r) => r.level === "none").map(bar)} />
    </div>
  );
}

/** The reviews by the invite's event type (the platform's word, as it sends it); none in the neutral hue */
export function ReviewInviteEvents({ rows, copy, locale }: { rows: ReviewsReport["inviteEvents"]; copy: Copy; locale: Locale }) {
  const t = copy.reviews;
  const n = (x: number) => fmtCount(x, locale);
  const largest = Math.max(0, ...rows.map((r) => r.reviews));
  const bar = (r: ReviewsReport["inviteEvents"][number]) => {
    const label = r.eventType ?? t.noEvent;
    return { key: label, label, share: barShare(r.reviews, largest), value: n(r.reviews),
      title: t.previousTitle.replace("{label}", label).replace("{reviews}", n(r.reviews)).replace("{previous}", n(r.previous)) };
  };
  const named = rows.filter((r) => r.eventType !== null);
  const none = rows.filter((r) => r.eventType === null);
  return (
    <div className="flex flex-col gap-4">
      {named.length > 0 ? <BarList testId="reviews-events" label={t.eventCard} className={FUNNEL_BAR_CLASS} bars={named.map(bar)} /> : null}
      {none.length > 0 ? <BarList testId="reviews-no-event" label={t.noEvent} className={FUNNEL_NEUTRAL_CLASS} bars={none.map(bar)} /> : null}
    </div>
  );
}
