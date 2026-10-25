/**
 * Reviews (addition 0008zd, brief B18; KPI 3): Reports → Reviews. The review platform (Trusted Shops for Pulse4all
 * Subscriptions) owns the reviews; the CMA polls them in hourly, maps them to markets through their channel and links
 * them to an order or a CRM contact where it can. The figures come from the database (cma.reviews_page); this module
 * mirrors their definitions for the mock and for verify/reports.mjs, and arranges them for the screen. Pure, with no
 * runtime imports beyond time.ts, reports.ts and funnel.ts, so the verifier runs it under Node's type stripping.
 *
 * The definitions (docs/definitions.md, Review terms; 102_reviews.sql):
 *   review          a review the platform holds of a channel; counted when it is published (the adapter reads the
 *                   platform's published state) and its channel is counted (configuration)
 *   day             the submission's date in the tenant's zone; the ISO week (Monday) likewise
 *   average rating  the mean rating of the counted reviews, two decimals (the review score)
 *   negative        rated at or below reviews.negative_max_rating (2 by default)
 *   whole star      a rating rounded up: star k holds the ratings above k - 1 up to k, so a negative review is whole stars
 *   link level      order (its transaction reference names one of the tenant's orders), contact (no order, a CRM contact
 *                   found by the reviewer's email, in memory only) or none
 *   market state    an active market's review channel: no_channel, channel_no_reviews, has_reviews
 * Team figures only: no figure per person exists. Ids, codes, counts and times only: never a reviewer or a review's text.
 */
import type {
  DateKey, FunnelGroup, Instant, ReviewFigures, ReviewLinkLevel, ReviewMarketState, ReviewsReport,
} from "./data/types";
// With their extensions, so verify/reports.mjs can run this module under Node's type stripping
import { inPeriod, type FunnelPrevious } from "./funnel.ts";
import { timeInZone } from "./reports.ts";
import { addDays, dateKeyInZone, startOfWeek } from "./time.ts";

export const REVIEW_LINK_LEVELS: readonly ReviewLinkLevel[] = ["order", "contact", "none"];
export const REVIEW_MARKET_STATES: readonly ReviewMarketState[] = ["no_channel", "channel_no_reviews", "has_reviews"];

/** A rating as a whole star: rounded up, 1 to 5 (4.5 is a 5; 1 is a 1) */
export function starsOf(rating: number): number {
  return Math.min(5, Math.max(1, Math.ceil(rating - 1e-9)));
}

/** A review as the mock holds it: the platform's facts and the channel's configuration */
export interface ReviewSource {
  reviewId: string;
  channel: string;
  channelName: string;
  /** The channel's market, or null when it has none */
  market: string | null;
  channelCounted: boolean;
  isPublished: boolean;
  rating: number;
  submittedAt: Instant;
  linkLevel: ReviewLinkLevel;
  inviteEventType: string | null;
}

/** A counted review with its business date and time, ISO week, whole star and whether it is negative (cma.reviews_of) */
export interface ReviewRecord extends ReviewSource {
  market: string;
  date: DateKey;
  time: string;
  week: DateKey;
  stars: number;
  isNegative: boolean;
}

/** The counted reviews (published, of a counted channel) in the tenant's zone, the market unknown without one */
export function reviewRecords(rows: readonly ReviewSource[], zone: string, negativeMaxRating: number): ReviewRecord[] {
  return rows.filter((r) => r.isPublished && r.channelCounted).map((r) => {
    const date = dateKeyInZone(r.submittedAt, zone);
    return { ...r, market: r.market ?? "unknown", date, time: timeInZone(r.submittedAt, zone), week: startOfWeek(date), stars: starsOf(r.rating),
      isNegative: r.rating <= negativeMaxRating };
  });
}

const round2 = (x: number) => Math.round(x * 100 + 1e-9) / 100;

/** The figures of a set of counted reviews (cma.review_figures) */
export function reviewFigures(rows: readonly ReviewRecord[]): ReviewFigures {
  return {
    reviews: rows.length,
    averageRating: rows.length === 0 ? null : round2(rows.reduce((s, r) => s + r.rating, 0) / rows.length),
    negative: rows.filter((r) => r.isNegative).length,
    linkedOrder: rows.filter((r) => r.linkLevel === "order").length,
    linkedContact: rows.filter((r) => r.linkLevel === "contact").length,
    unlinked: rows.filter((r) => r.linkLevel === "none").length,
  };
}

/** An active market as the states need it */
export interface ReviewMarket {
  code: string;
  name: string;
  sortOrder: number;
}

/** A channel as the states need it: its market, counted, still at the source, and its published reviews */
export interface ReviewChannelState {
  market: string | null;
  isCounted: boolean;
  deleted: boolean;
  publishedReviews: number;
}

/** Every active market with its review-channel state (cma.review_market_states_of), in the markets' order */
export function reviewMarketStates(markets: readonly ReviewMarket[], channels: readonly ReviewChannelState[]): ReviewsReport["marketStates"] {
  return [...markets].sort((a, b) => a.sortOrder - b.sortOrder || a.code.localeCompare(b.code)).map((m) => {
    const own = channels.filter((c) => c.market === m.code && c.isCounted && !c.deleted);
    const reviews = own.reduce((s, c) => s + c.publishedReviews, 0);
    const state: ReviewMarketState = own.length === 0 ? "no_channel" : reviews === 0 ? "channel_no_reviews" : "has_reviews";
    return { market: m.code, name: m.name, state, channels: own.length, reviews };
  });
}

/** The page as cma.reviews_page_of answers it; `records` every counted review up to now, for the history start */
export function reviewsReport(records: readonly ReviewRecord[], opts: {
  from: DateKey; to: DateKey; group: FunnelGroup; market: string | null; prev: FunnelPrevious; zone: string; negativeMaxRating: number;
  connected: boolean; markets: readonly ReviewMarket[]; marketStates: ReviewsReport["marketStates"]; filterMarkets: string[];
}): ReviewsReport {
  const { from, to, group, market, prev, zone } = opts;
  const until = prev.until === null ? null : timeInZone(prev.until, zone);
  const all = records.filter((r) => market === null || r.market === market);
  const cur = all.filter((r) => inPeriod(r.date, r.time, from, to, null));
  const pre = all.filter((r) => inPeriod(r.date, r.time, prev.from, prev.to, until));
  const sortOf = new Map(opts.markets.map((m) => [m.code, m.sortOrder]));
  const nameOf = new Map(opts.markets.map((m) => [m.code, m.name]));
  const marketOrder = (a: string, b: string) => (a === "unknown" ? 1 : 0) - (b === "unknown" ? 1 : 0)
    || (sortOf.get(a) ?? Number.MAX_SAFE_INTEGER) - (sortOf.get(b) ?? Number.MAX_SAFE_INTEGER) || a.localeCompare(b);
  const keys: DateKey[] = [];
  for (let d = group === "week" ? startOfWeek(from) : from; d <= to; d = addDays(d, group === "week" ? 7 : 1)) keys.push(d);
  const channels = [...new Map([...cur, ...pre].map((r) => [r.channel, { channel: r.channel, name: r.channelName, market: r.market }])).values()]
    .sort((a, b) => a.name.localeCompare(b.name) || a.channel.localeCompare(b.channel));
  const events = [...new Set([...cur, ...pre].map((r) => r.inviteEventType))].map((eventType) => ({
    eventType, reviews: cur.filter((r) => r.inviteEventType === eventType).length, previous: pre.filter((r) => r.inviteEventType === eventType).length,
  })).sort((a, b) => b.reviews - a.reviews || (a.eventType === null ? 1 : 0) - (b.eventType === null ? 1 : 0) || (a.eventType ?? "").localeCompare(b.eventType ?? ""));
  return {
    from, to, group, market,
    current: reviewFigures(cur), previous: reviewFigures(pre),
    previousFrom: prev.from, previousTo: prev.to, previousPartial: prev.until !== null,
    distribution: [1, 2, 3, 4, 5].map((stars) => ({ stars, reviews: cur.filter((r) => r.stars === stars).length, previous: pre.filter((r) => r.stars === stars).length })),
    byPeriod: keys.map((key) => ({ key, ...reviewFigures(cur.filter((r) => (group === "week" ? r.week : r.date) === key)) })),
    byMarket: [...new Set([...cur, ...pre].map((r) => r.market))].sort(marketOrder).map((m) => ({
      market: m, name: nameOf.get(m) ?? null, current: reviewFigures(cur.filter((r) => r.market === m)), previous: reviewFigures(pre.filter((r) => r.market === m)),
    })),
    byChannel: channels.map((c) => ({ ...c, current: reviewFigures(cur.filter((r) => r.channel === c.channel)), previous: reviewFigures(pre.filter((r) => r.channel === c.channel)) })),
    linkLevels: REVIEW_LINK_LEVELS.map((level) => ({ level, reviews: cur.filter((r) => r.linkLevel === level).length, previous: pre.filter((r) => r.linkLevel === level).length })),
    inviteEvents: events,
    marketStates: opts.marketStates,
    historyStart: all.reduce<DateKey | null>((m, r) => (m === null || r.date < m ? r.date : m), null),
    negativeMaxRating: opts.negativeMaxRating, connected: opts.connected, markets: opts.filterMarkets,
  };
}

/** A rating with two decimals at most in the reader's language ("4.25", "4"); a dash without one */
export function fmtRating(value: number | null, locale: "en" | "nl"): string {
  if (value === null) return "–";
  return new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB", { maximumFractionDigits: 2 }).format(value);
}

/** The share of the counted reviews a part is, for the bars and the link levels; null without reviews */
export function reviewShare(part: number, whole: number): number | null {
  return whole === 0 ? null : part / whole;
}

/** The markets that have no counted channel, for the page's data-first notice (KPI 11) */
export function marketsWithoutChannel(states: ReviewsReport["marketStates"]): string[] {
  return states.filter((s) => s.state === "no_channel").map((s) => s.market);
}
