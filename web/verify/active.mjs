/**
 * Verifier: Customers → Active (addition 0009l, brief B35 with addendum A), without a browser, a server or a database:
 * the pure functions of src/lib/active.ts, the page's copy, the page's types and the mock's document.
 *
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/active.mjs             every check must PASS
 *   node --experimental-strip-types --import ./verify/lib/alias.mjs verify/active.mjs --provoke   every check must FAIL
 *
 * Checks:
 *   U  the unit factor per billing interval (a day 365.25/12, a week 365.25/84, a month 1, a year 1/12, each divided by the
 *      count) and the billing words
 *   S  the active spells of a set of holding intervals against a day-by-day brute force over 300 random sets (overlaps,
 *      gaps, an interval that begins where another ends, one without an end, one of no length)
 *   K  Kaplan–Meier against a hand-computed table (ties, a spell censored at the age of an event, one spell, a curve that
 *      never reaches 50 %) and against a brute force over 200 random sets of spells
 *   D  a difference between two segments: never coloured (no better or worse), its sign always written
 *   C  the change against an earlier month end, the cohort's share and maturity, the range and its first month
 *   H  the heatmap's scale (one hue, monotonic, 4.5:1 on every step, white only from Denim on), the sparkline's path, the axis
 *   F  the filter from an address (what is out of its form is refused and named), the address back, the file's name
 *   J  the database's document in the API's words: camelCase keys, the data-keyed maps kept as they are
 *   T  the copy: every key the page reads exists in both languages, every channel, slot, measure, reason, payment state,
 *      billing word and sort column has its words
 *   P  no field of the page's types could hold a name, an email, a phone number or an address
 *   X  the placeholders render no digit: their labels, their badge, their sources and the mock's slots carry none, and the
 *      placeholder card writes no number
 *   N  the stored take, the reads and the list's cursors (decisions D13 to D15): each read its own part, the take on every
 *      read, keyset paging with a cursor that is an id alone, the page's client code, the streamed parts and heights
 *   O  the table first, the live present after (decision D16): the live tiles in the places of the stored ones, nothing a
 *      zero without a take, a stale and a late take saying so, the frame reading nothing from the database
 *   M  the mock's document: net change = inflow − outflow = this month end − the previous one, the running month equals
 *      the headline, the three channels and the segments add up to the unfiltered totals, a tenant without a store shows
 *      nothing (never zeros), a person without the report permissions is refused
 */
import { readFileSync } from "node:fs";
import {
  ACTIVE_CHANNELS, ACTIVE_CURSOR, ACTIVE_FILE_COLUMNS, ACTIVE_MEASURE_METRIC, ACTIVE_PANEL_HEIGHT, ACTIVE_PARTS, ACTIVE_SCROLLING, ACTIVE_SLOTS, ACTIVE_SORTS,
  HEAT_DARK_EDGE, HEAT_DENIM, HEAT_FROM, HEAT_LIGHT_EDGE, HEAT_TO, LINE_COLOURS, activeFileName, activeFromDb, activeInTakeState, activeListInTakeState, activeNowFromDb, activeNowInTakeState, activePartOf, withActiveNow,
  activeQuery, activeRangeOf, billingOf, changeAgainst, cohortShare, contrast, counted, curveOf, fromMonthOf, heatColour, heatTextRgb, kaplanMeier, lineStyle, luminance, matureCohorts, monthsBack,
  mergeActive, niceAxis, parseActiveFilter, retentionAt, signed, sparkPath, spellsOf, unitFactor, wholePercents,
} from "../src/lib/active.ts";
import { activeCopy, copy } from "../src/lib/copy.ts";
import { mockActive, mockActiveNow, mockActiveRows } from "../src/lib/data/mock-active.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(86)} got ${JSON.stringify(actual).slice(0, 90)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 90)}`}`);
}
const src = (p) => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8");
/** A small deterministic generator, so a failure names the same set every run */
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}
const r6 = (x) => Math.round(x * 1e6) / 1e6;

// ---- U. The unit factors -------------------------------------------------------------------------------------------------
expect("U1 a day 365.25/12, a week 365.25/84, a month 1, a year 1/12, each divided by the count; none without either",
  [r6(unitFactor("day", 1)), r6(unitFactor("day", 30)), r6(unitFactor("week", 1)), r6(unitFactor("week", 4)), unitFactor("month", 1), r6(unitFactor("month", 3)),
    r6(unitFactor("year", 1)), unitFactor(null, 1), unitFactor("month", null), unitFactor("month", 0), unitFactor("fortnight", 1)],
  [30.4375, 1.014583, 4.348214, 1.087054, 1, 0.333333, 0.083333, null, null, null, null],
  [30, 1, 4, 1, 1, 0.333333, 0.083333, null, null, null, null]);
expect("U2 the billing words: monthly, yearly (a year, or twelve months), other, unknown",
  [billingOf("month", 1), billingOf("year", 1), billingOf("month", 12), billingOf("week", 4), billingOf("month", 3), billingOf(null, 1)],
  ["monthly", "yearly", "yearly", "other", "other", "unknown"], ["monthly", "yearly", "other", "other", "other", "other"]);

// ---- S. The spells against a brute force -----------------------------------------------------------------------------------
/** Day by day: a key holds on a day when an interval covers it; a spell is a run of held days, its end the first day not held */
function bruteSpells(intervals, days) {
  const keys = [...new Set(intervals.filter((i) => i.start !== null).map((i) => i.key))].sort();
  const out = [];
  for (const key of keys) {
    const own = intervals.filter((i) => i.key === key && i.start !== null && (i.end === null || i.end > i.start));
    let open = null;
    for (let d = 0; d <= days; d += 1) {
      const held = own.some((i) => i.start <= d && (i.end === null || i.end > d));
      if (held && open === null) open = d;
      if (!held && open !== null) {
        out.push({ key, start: open, end: d });
        open = null;
      }
    }
    if (open !== null) out.push({ key, start: open, end: null });
  }
  return out;
}
{
  const rand = rng(172);
  let differ = 0;
  let first = null;
  for (let n = 0; n < 300; n += 1) {
    const intervals = Array.from({ length: 2 + Math.floor(rand() * 8) }, () => {
      const start = Math.floor(rand() * 100);
      const kind = rand();
      return { key: `k${1 + Math.floor(rand() * 3)}`, start: kind < 0.05 ? null : start, end: kind < 0.2 ? null : kind < 0.3 ? start : start + 1 + Math.floor(rand() * 30) };
    });
    const got = JSON.stringify(spellsOf(intervals));
    const want = JSON.stringify(bruteSpells(intervals, 140));
    if (got !== want) {
      differ += 1;
      first ??= { n, got, want };
    }
  }
  expect("S1 spellsOf equals the day-by-day brute force on 300 random sets", { sets: 300, differ, first }, { sets: 300, differ: 0, first: null }, { sets: 300, differ: 1, first: null });
}
expect("S2 an interval that begins where another ends continues the spell; a gap splits it; no length, no spell",
  spellsOf([{ key: "a", start: 1, end: 5 }, { key: "a", start: 5, end: 9 }, { key: "a", start: 12, end: null }, { key: "b", start: 3, end: 3 }, { key: "c", start: null, end: 4 }]),
  [{ key: "a", start: 1, end: 9 }, { key: "a", start: 12, end: null }],
  [{ key: "a", start: 1, end: 5 }, { key: "a", start: 5, end: 9 }, { key: "a", start: 12, end: null }]);

// ---- K. Kaplan–Meier ---------------------------------------------------------------------------------------------------------
{
  // ten spells: 1 ended, 2 ended, 2 ended (a tie), 2 still active (censored at the age of an event), 3 ended, 5 still, 5 ended, 6 still, 8 ended, 8 still
  const lengths = [1, 2, 2, 2, 3, 5, 5, 6, 8, 8];
  const ended = [true, true, true, false, true, false, true, false, true, false];
  expect("K1 the hand-computed table: at risk / events / survival per age, the median 5 where the curve first is at or below half",
    [kaplanMeier(lengths, ended).map((p) => `${p.age}:${p.atRisk}/${p.events}/${p.survival}`).join(" "), curveOf(lengths, ended).median],
    ["0:10/0/1 1:10/1/0.9 2:9/2/0.7 3:6/1/0.583333 4:5/0/0.583333 5:5/1/0.466667 6:3/0/0.466667 7:2/0/0.466667 8:2/1/0.233333", 5],
    ["0:10/0/1", 4]);
  const one = curveOf([4], [false]);
  const two = curveOf([3, 3], [true, false]);
  expect("K2 one spell still active: no median (not reached), the longest 4; an event and a censored spell of 3: the median 3, where the retention is a half; no retention past the longest; none: empty",
    [one.median, one.longest, one.curve.map((p) => p.survival), two.median, retentionAt(two, 3), retentionAt(two, 2), retentionAt(two, 4), curveOf([], []).curve.length],
    [null, 4, [1, 1, 1, 1, 1], 3, 0.5, 1, null, 0], [4, 4, [1, 1, 1, 1, 1], null, 1, 0.5, 0, 1]);
  // a brute force: survival as the product by its definition, at risk and events counted per age from the raw list
  const rand = rng(173);
  let differ = 0;
  for (let n = 0; n < 200; n += 1) {
    const size = 1 + Math.floor(rand() * 40);
    const ls = Array.from({ length: size }, () => Math.floor(rand() * 24));
    const es = ls.map(() => rand() < 0.5);
    let s = 1;
    const want = [];
    for (let age = 0; age <= Math.max(...ls); age += 1) {
      let atRisk = 0;
      let events = 0;
      for (let i = 0; i < size; i += 1) {
        if (ls[i] >= age) atRisk += 1;
        if (es[i] && ls[i] === age) events += 1;
      }
      if (atRisk > 0) s *= (atRisk - events) / atRisk;
      want.push({ age, atRisk, events, survival: r6(s) });
    }
    const got = kaplanMeier(ls, es);
    const close = got.length === want.length && got.every((p, i) => p.atRisk === want[i].atRisk && p.events === want[i].events
      && Math.abs(p.survival - want[i].survival) < 2e-6);
    if (!close) differ += 1;
  }
  expect("K3 kaplanMeier equals the brute force on 200 random sets of spells", { sets: 200, differ }, { sets: 200, differ: 0 }, { sets: 200, differ: 1 });
}

// ---- D. A difference between two segments: its sign, never a colour -----------------------------------------------------------
{
  const parts = src("components/ActiveParts.tsx");
  const table = parts.slice(parts.indexOf("export function ComparisonTable"), parts.indexOf("export function CohortHeatmap"));
  expect("D1 between two segments there is no better or worse: no difference or ratio is coloured green or red, every one stands in Inkt",
    [/text-p4a-(green|error)/.test(table), /data-tone/.test(table), (table.match(/text-p4a-inkt/g) ?? []).length, "differenceTone" in await import("../src/lib/active.ts")],
    [false, false, 2, false], [true, true, 0, true]);
  expect("D2 the sign of a difference is always written; zero carries none",
    [signed("2", 2), signed("2", -2), signed("0", 0)], ["+2", "−2", "0"], ["2", "-2", "+0"]);
}

// ---- C. Change lines, cohorts, the range -----------------------------------------------------------------------------------
expect("C1 a change against an earlier month end: its direction and size; none where the history does not reach (never 0)",
  [changeAgainst(8, 6), changeAgainst(6, 8).direction, changeAgainst(6, 6).direction, changeAgainst(6, null), changeAgainst(null, 6).direction],
  [{ direction: "up", delta: 2, pct: 2 / 6 }, "down", "flat", { direction: "none", delta: null, pct: null }, "none"],
  [{ direction: "up", delta: 2, pct: 0 }, "up", "none", { direction: "flat", delta: 0, pct: null }, "flat"]);
{
  const cohorts = [
    { cohort: "2026-10-01", started: 8, share: 0.1, ages: [{ age: 3, stillActive: 0, mature: false }] },
    { cohort: "2026-05-01", started: 10, share: 0.2, ages: [{ age: 3, stillActive: 9, mature: true }, { age: 6, stillActive: 4, mature: false }] },
    { cohort: "2026-04-01", started: 0, share: 0, ages: [{ age: 3, stillActive: 0, mature: true }] },
  ];
  const two = { cohort: "2026-03-01", started: 5, share: 0.1, ages: [{ age: 3, stillActive: 5, mature: true }, { age: 6, stillActive: 4, mature: true }, { age: 12, stillActive: 4, mature: false }] };
  expect("C2 a cohort's share only where it is Mature; a curve only for a cohort Mature at two ages or more (one mature age is a lone dot)",
    [cohortShare(cohorts[1], cohorts[1].ages[0]), cohortShare(cohorts[1], cohorts[1].ages[1]), cohortShare(cohorts[2], cohorts[2].ages[0]), matureCohorts([...cohorts, two], 6).map((c) => c.cohort),
      matureCohorts(Array.from({ length: 9 }, (_, i) => ({ ...two, cohort: `c${i}` })), 6).length],
    [0.9, null, null, ["2026-03-01"], 6], [0.9, 0.4, 0, ["2026-05-01", "2026-03-01"], 9]);
  // the lines' colours: Deep Blue, Leaf Green, Denim, Inkt, Light Blue of the series order (never Soft Rose, index 4); the sixth dashed
  const page = src("app/reports/active/page.tsx");
  expect("C4 no line takes Soft Rose: five colours, the sixth line the first colour again, dashed; the retention's x is the age in months",
    [[...LINE_COLOURS], LINE_COLOURS.includes(4), [0, 4, 5, 6].map((i) => lineStyle(i)), /colour: \[[^\]]*\b4\b[^\]]*\]\[i %/.test(page), /x: a\.age, y: share/.test(page), /xLabels=\{\[\{ x: 0, text: "0" \}, \.\.\.ages\.filter\(\(a\) => a <= reach\)\.map\(\(a\) => \(\{ x: a,/.test(page)],
    [[0, 1, 3, 5, 2], false, [{ colour: 0, dashed: false }, { colour: 2, dashed: false }, { colour: 0, dashed: true }, { colour: 1, dashed: true }], false, true, true],
    [[0, 1, 2, 3, 4], true, [{ colour: 0, dashed: false }, { colour: 4, dashed: false }, { colour: 5, dashed: false }, { colour: 0, dashed: true }], true, false, false]);
}
expect("C3 the range: 24 months unless 12, 36 or all; its first month; all starts where the database's cap puts it",
  [activeRangeOf(undefined), activeRangeOf("36"), activeRangeOf("48"), fromMonthOf("24", "2026-11-11"), fromMonthOf("12", "2026-01-31"), fromMonthOf("all", "2026-11-11"), monthsBack("2026-03-15", 13)],
  ["24", "36", "24", "2024-11-01", "2025-01-01", null, "2025-02-01"], ["12", "36", "48", "2024-11-11", "2025-01-31", "2021-11-01", "2025-02-15"]);

// ---- H. The heatmap, the sparkline, the axis --------------------------------------------------------------------------------
{
  // every whole percent of the scale: its background, its text, the contrast between the two
  const steps = Array.from({ length: 101 }, (_, p) => heatColour(p / 100));
  const lum = steps.map((h) => luminance(h.rgb));
  const ratios = steps.map((h) => contrast(h.rgb, heatTextRgb(h.text)));
  const hex = (rgb) => `#${rgb.map((v) => v.toString(16).padStart(2, "0")).join("").toUpperCase()}`;
  expect("H1 the heatmap: one hue from #EAF4FC (0 %) to #265BA4 (100 %), never lighter for a higher share (70 % is never darker than 80 %)",
    [hex(steps[0].rgb), hex(steps[100].rgb), lum.every((l, i) => i === 0 || l <= lum[i - 1] + 1e-12), lum[70] >= lum[80], new Set(steps.map((h) => h.background)).size > 80,
      heatColour(null), heatColour(1.4).percent, heatColour(-1).percent, hex([...HEAT_FROM]), hex([...HEAT_TO])],
    ["#EAF4FC", "#265BA4", true, true, true, null, 100, 0, "#EAF4FC", "#265BA4"], ["#FFFFFF", "#000000", false, false, false, { percent: 0 }, 140, -100, "#EAF4FC", "#265BA4"]);
  expect("H1b every one of the 101 steps reads at 4.5:1 or more; white text only where the background is at least as dark as Denim (#3B6FB3), Inkt on the lighter half",
    [ratios.filter((r) => r < 4.5).length, Math.round(Math.min(...ratios) * 100) / 100, steps.filter((h) => h.text === "white" && luminance(h.rgb) > luminance(HEAT_DENIM)).length,
      steps.slice(0, 51).every((h) => h.text === "inkt"), steps[100].text, HEAT_LIGHT_EDGE, HEAT_DARK_EDGE, steps.findIndex((h) => h.text === "white")],
    [0, 4.59, 0, true, "white", 74, 87, 81], [1, 3, 1, false, "inkt", 0, 100, 0]);
  const parts = src("components/ActiveParts.tsx");
  expect("H1c the cells take the scale's colour and a legend from 0 % to 100 % stands under the heatmap",
    [/style=\{\{ backgroundColor: heat\.background \}\}/.test(parts), /data-testid="active-heat-legend"/.test(parts), /fmtShare\(0, locale\)[\s\S]{0,400}fmtShare\(1, locale\)/.test(parts), /text-white" : "text-p4a-inkt"/.test(parts)],
    [true, true, true, true], [false, false, false, false]);
}
{
  const path = sparkPath([3, 4, 3, 6, 6], 80, 20);
  const points = [...path.matchAll(/[ML]([\d.]+) ([\d.]+)/g)].map((m) => [Number(m[1]), Number(m[2])]);
  expect("H2 a sparkline: a point per value, inside its 80 by 20 box, the highest on top; a flat line in the middle; none without a value",
    [points.length, points.every(([x, y]) => x >= 0 && x <= 80 && y >= 0 && y <= 20), points[3][1] < points[0][1], sparkPath([5, 5], 80, 20), sparkPath([], 80, 20)],
    [5, true, true, "M2 10 L78 10", ""], [4, false, false, "M0 0 L80 0", "M0 0"]);
}
expect("H3 an axis from 0 (or below, for bars that go down) to a round top",
  [niceAxis(0, 281), niceAxis(-9, 58), niceAxis(0, 0).top > 0], [{ top: 300, bottom: 0, step: 100 }, { top: 60, bottom: -20, step: 20 }, true],
  [{ top: 281, bottom: 0, step: 70.25 }, { top: 58, bottom: -9, step: 16.75 }, false]);

// ---- F. The filter and the file's name ---------------------------------------------------------------------------------------
expect("F1 the filter from an address: a market code or unknown, a segment's code, a channel; what is out of its form is refused and named",
  [parseActiveFilter("NL", "B2B", "indirect"), parseActiveFilter("nl", null, null).problem, parseActiveFilter(null, "a b", null).problem,
    parseActiveFilter(null, null, "assisted").problem, parseActiveFilter("unknown", "unknown", "unknown").problem, parseActiveFilter("", undefined, []).filter],
  [{ filter: { market: "NL", segment: "B2B", channel: "indirect" }, problem: null }, "market", "segment", "channel", null, { market: null, segment: null, channel: null }],
  [{ filter: { market: "NL", segment: "B2B", channel: "indirect" }, problem: "channel" }, null, null, null, "market", { market: "", segment: null, channel: null }]);
expect("F2 the address holds only what is chosen; the file's name: market, segment, the channel when chosen, the stamp; ids and codes only",
  [activeQuery({ market: "GB", segment: null, channel: "direct" }), activeFileName({ market: null, segment: null, channel: null }, "2026-11-11T1630"),
    activeFileName({ market: "GB", segment: "B2B", channel: "indirect" }, "2026-11-11T1630"), ACTIVE_FILE_COLUMNS.filter((c) => /name|email|phone|address/.test(c))],
  [{ market: "GB", channel: "direct" }, "active-customers-all-all-2026-11-11T1630.csv", "active-customers-gb-b2b-indirect-2026-11-11T1630.csv", []],
  [{ market: "GB", segment: "", channel: "direct" }, "active-customers.csv", "active-customers-GB-B2B-2026-11-11T1630.csv", ["contact_name"]]);

// ---- J. The database's document in the API's words --------------------------------------------------------------------------
{
  const doc = activeFromDb({
    figures: true, set_up: { commerce: true, subscriptions: true }, computed_at: "2026-11-11T12:00:00Z", from_month: "2024-11-01",
    settings: { cohort_ages_months: [3], age_months: [12], history_months: 60, fx: { as_of: "2026-11-01", GBP: 1.15 }, segments: ["key_account", "B2C"],
      statuses: { active_subscription_statuses: ["active"], device_holding_statuses: ["active", "failed"], ended_subscription_statuses: ["canceled"] } },
    tiles: { active_customers: { value: 2, by_segment: { key_account: 1, B2C: 1 }, by_channel: { indirect: 1, direct: 0, unknown: 1 }, prev_month: 2, prev_year: null },
      total_subscriptions: { value: 2, by_status: { "never-subscribed": 0, active: 2 } }, amounts: [{ currency: "EUR", average_prev_month: 1 }], clv: { EUR: { per_month: 3 } } },
    months: [{ month: "2026-11-01", is_now: true, inflow_by_channel: { unknown: 1 }, amounts: { EUR: 10 } }],
    markets: [], markets_total: { churned_30d: 1 }, comparison: { rows: [{ a_longest: 4 }] }, survival: { all: { curve: [{ at_risk: 2 }] }, segment: [], channel: [] },
    age_bands: [], cohorts: [{ ages: [{ still_active: 1 }] }], cohort_splits: { segment: [], channel: [] },
    mix: { billing: [], device_band: [{ key: "1", subscriptions: 2 }], model: [{ key: "m", name: "Model", devices: 2 }], payment_state: [] },
    unit_economics: { churned_30d: 1, slots: [{ key: "churn_rate", status: "pending" }] },
    notes: { no_ended_time: 1, unknown_channel: { customers: 1, reasons: { no_order_deal: 1 } }, history_starts: [] }, filters: { markets: [], segments: [], channels: [] },
  });
  expect("J1 camelCase keys; a segment's code, a status, a currency and a reason kept as the database writes them; the rates apart from their date",
    [Object.keys(doc.tiles.activeCustomers.bySegment), Object.keys(doc.tiles.totalSubscriptions.byStatus), doc.tiles.activeCustomers.prevMonth, doc.tiles.amounts[0].averagePrevMonth,
      doc.tiles.clv.EUR.perMonth, doc.months[0].isNow, doc.months[0].inflowByChannel, doc.notes.unknownChannel.reasons, doc.settings.fx, doc.settings.statuses.holding,
      doc.mix.deviceBand[0].subscriptions, doc.mix.model[0].label, doc.survival.all.curve[0].atRisk, doc.cohorts[0].ages[0].stillActive, doc.comparison.rows[0].aLongest,
      doc.unitEconomics.churned30d, doc.marketsTotal.churned30d, doc.fromMonth],
    [["key_account", "B2C"], ["never-subscribed", "active"], 2, 1, 3, true, { unknown: 1 }, { no_order_deal: 1 }, { asOf: "2026-11-01", rates: { GBP: 1.15 } }, ["active", "failed"],
      2, "Model", 2, 1, 4, 1, 1, "2024-11-01"],
    [["keyAccount", "B2C"], ["neverSubscribed", "active"], 2, 1, 3, true, { unknown: 1 }, { noOrderDeal: 1 }, { asOf: "2026-11-01", rates: { GBP: 1.15, asOf: 0 } }, [], 2, "Model", 2, 1, 4, 1, 1, null]);
  const off = activeFromDb({ figures: false, set_up: { commerce: false, subscriptions: true }, settings: {} });
  expect("J2 not set up: no tile, no slot, no month, no market (never zeros)",
    [off.figures, off.tiles, off.unitEconomics, off.months, off.markets, off.marketsTotal, off.setUp], [false, null, null, [], [], null, { commerce: false, subscriptions: true }],
    [true, {}, {}, [{}], [{}], {}, null]);
}

// ---- T. The copy ---------------------------------------------------------------------------------------------------------------
{
  const pageFiles = ["app/reports/active/page.tsx", "components/ActiveParts.tsx", "components/ActiveFilters.tsx"];
  const text = pageFiles.map(src).join("\n");
  // every t.<key> the page reads (t is activeCopy[locale] in all three files), every hints.mh_<key>, and the list's header keys
  const used = new Set([...text.matchAll(/\bt\.([A-Za-z_][A-Za-z0-9_]*)/g)].map((m) => m[1]));
  for (const m of text.matchAll(/hints\.(mh_[a-z0-9_]+)/g)) used.add(m[1]);
  for (const m of text.matchAll(/head\("([A-Za-z]+)"/g)) used.add(m[1]);
  const dynamic = [
    ...ACTIVE_CHANNELS.flatMap((c) => [`channel_${c}`, `channelShort_${c}`]), ...ACTIVE_SLOTS.flatMap((s) => [`slot_${s.key}`, `mh_slot_${s.key}`, ...s.fedBy.map((f) => `feed_${f}`)]),
    ...Object.keys(ACTIVE_MEASURE_METRIC).map((m) => `m_${m}`), ...["no_contact", "before_history", "no_first_order", "order_not_matched", "no_order_deal"].map((r) => `reason_${r}`),
    ...["paid", "in_retry", "failed", "paused"].map((p) => `pay_${p}`), ...["monthly", "yearly", "other", "unknown"].map((b) => `billing_${b}`), "grouping_month", "grouping_quarter",
  ];
  const wanted = [...used, ...dynamic];
  const missing = (lang) => wanted.filter((k) => typeof activeCopy[lang][k] !== "string" || activeCopy[lang][k] === "");
  expect("T1 every key the page reads, and every channel, slot, measure, reason, payment state and billing word, has its words in en and nl",
    [wanted.length > 150, missing("en"), missing("nl"), copy.en.nav.active, copy.nl.nav.active, activeCopy.en.title, activeCopy.nl.title],
    [true, [], [], "Active", "Actief", "Active customers", "Actieve klanten"], [true, ["provoked"], ["provoked"], "Active", "Actief", "Active", "Actief"]);
  expect("T2 the labels of decision D9, and Unknown never worded as direct",
    [activeCopy.en.channel, activeCopy.nl.channel, activeCopy.en.channel_indirect, activeCopy.nl.channel_indirect, activeCopy.en.channel_direct, activeCopy.nl.channel_direct,
      activeCopy.en.channel_unknown, activeCopy.nl.channel_unknown],
    ["Direct / Indirect", "Direct / Indirect", "Indirect · call center", "Indirect · callcenter", "Direct · self-service", "Direct · selfservice", "Unknown", "Onbekend"],
    ["Channel", "Kanaal", "Assisted", "Geholpen", "Direct", "Direct", "Direct", "Direct"]);
  const retired = /\b(tenure|lifetime value|churn rate %)\b/i;
  expect("T3 the page says Customer age, never tenure; First orders' hints name Indirect and Direct on Customers, Active",
    [Object.values(activeCopy.en).filter((v) => /\btenure\b/i.test(v)).length, retired.test(activeCopy.en.customerAge), /Indirect/.test(copy.en.hints.foCallCenter),
      /Direct/.test(copy.en.hints.foSelfService), /Indirect/.test(copy.nl.hints.foCallCenter), /Direct/.test(copy.nl.hints.foSelfService)],
    [0, false, true, true, true, true], [1, true, false, false, false, false]);
}

// ---- P. No personal field in the page's types ----------------------------------------------------------------------------------
{
  const types = src("lib/data/types.ts");
  const from = types.indexOf("export type ActiveChannel");
  const to = types.indexOf("export type MaintenanceScope");
  const block = types.slice(from, to);
  const fields = [...block.matchAll(/(?:^|[{;,(]\s*)([A-Za-z_][A-Za-z0-9_]*)\??:/gm)].map((m) => m[1]);
  const personal = /name|email|mail|phone|mobile|address|street|city|postal|zip|birth|iban|firstname|lastname/i;
  expect("P1 the page's types hold no field that could hold a name, an email, a phone number or an address",
    [from > 0 && to > from, fields.length > 100, [...new Set(fields.filter((f) => personal.test(f)))]], [true, true, []], [true, true, ["displayName"]]);
  const list = mockActiveRows({ tenantId: "t1", permissions: ["reports.view"] }, { filter: { market: null, segment: null, channel: null }, sort: "monthly_amount", descending: true, offset: 0, limit: 50 });
  const keys = [...new Set(list.rows.flatMap((r) => Object.keys(r)))].sort();
  expect("P2 a list row's keys: ids, codes, dates, amounts and the contact's link; none personal; no @ in any value",
    [keys, keys.filter((k) => personal.test(k)), JSON.stringify(list.rows).includes("@")],
    [["ageMonths", "channel", "clv", "clvCurrency", "contactId", "contactUrl", "currency", "customerStart", "devices", "level", "market", "monthlyAmount", "otherAmounts", "paymentState",
      "segment", "store", "storeCustomer", "subscriptions"], [], false], [["name"], ["name"], true]);
}

// ---- W. Whole percentages of a split, and a count's singular --------------------------------------------------------------------
{
  const rand = rng(20261112);
  let bad = 0;
  let sets = 0;
  for (let i = 0; i < 2000; i += 1) {
    const parts = Array.from({ length: 1 + Math.floor(rand() * 7) }, () => (rand() < 0.15 ? 0 : Math.floor(rand() * (rand() < 0.5 ? 20 : 5000))));
    const total = parts.reduce((a, b) => a + b, 0);
    const got = wholePercents(parts);
    sets += 1;
    const sum = got.reduce((a, b) => a + b, 0);
    // adds up to 100 (or 0 for an empty split), every part within one point of its exact share, whole, never negative, a zero part 0
    const ok = sum === (total > 0 ? 100 : 0) && got.every((p, k) => Number.isInteger(p) && p >= 0 && (total === 0 || Math.abs(p - (parts[k] / total) * 100) < 1) && (parts[k] > 0 || p === 0));
    if (!ok) bad += 1;
  }
  expect("W1 a split in whole percentages adds up to 100 by the largest remainder: 2,000 random splits, each part within a point of its share",
    [sets, bad, wholePercents([9.4, 9.5, 81.1].map((x) => x * 10)), wholePercents([1, 1, 1]), wholePercents([0, 0]), wholePercents([5]), wholePercents([176, 20, 22])],
    [2000, 0, [9, 10, 81], [34, 33, 33], [0, 0], [100], [81, 9, 10]], [2000, 1, [9, 10, 82], [33, 33, 33], [50, 50], [99], [81, 9, 11]]);
  const page = src("app/reports/active/page.tsx");
  const parts = src("components/ActiveParts.tsx");
  expect("W2 the page's splits use it: the channels under Active customers, the markets' shares, the comparison's share of the base; a part that rounds to nothing reads < 1%",
    [/wholePercents\(ACTIVE_CHANNELS\.map/.test(page), /wholePercents\(rows\.map\(\(r\) => r\.share \?\? 0\)\)/.test(parts), /wholePercents\(\[r\.a \?\? 0, r\.b \?\? 0, r\.unknown \?\? 0\]\)/.test(parts),
      /percent === 0 && part > 0 \? 0\.4 : percent/.test(parts)], [true, true, true, true], [false, false, false, false]);
  const t = activeCopy;
  const forms = ["monthsValue", "moreThanMonths", "moreThan", "notReached", "pointsValue", "m_retention", "medianIs", "spellsCount", "bandMonths", "devicesBand", "noteUnknownChannel"];
  expect("W3 one month, one device: every unit has a singular for exactly 1, in en and nl; the survival legend's words; a reason per line",
    [counted(t.en.monthsValue, 1), counted(t.en.monthsValue, 2), counted(t.en.devicesBand, 1), counted(t.en.devicesBand, 2, "2–5"), counted(t.nl.monthsValue, 1), counted(t.nl.devicesBand, 1),
      counted(t.en.notReached, 29), counted(t.en.spellsCount, 67), counted("{n} x", 1), counted(t.en.monthsValue, 1, "1.0"),
      forms.filter((k) => ["en", "nl"].some((l) => t[l][k].split("|").length !== 2 || !t[l][k].split("|").every((f) => f.includes("{n}")))),
      Object.keys(t.en).filter((k) => k.startsWith("reason_")).every((k) => /^[A-Z]/.test(t.en[k]) && /^[A-Z]/.test(t.nl[k])),
      /data-reason=\{k\}>[^\n]*\}: \$\{n\(v\)\}`\}<\/span>/.test(page), /noteAttributionStart\.replace\("\{date\}", fmtDate\([^)]*, "full"\)\)/.test(page)],
    ["1 month", "2 months", "1 device", "2–5 devices", "1 maand", "1 apparaat", "not reached yet, more than 29 months", "67 active periods", "1 x", "1.0 month", [], true, true, true],
    ["1 months", "2 month", "1 devices", "2–5 device", "1 maanden", "1 apparaten", "Not reached yet: more than 29 months", "67 active period", "1", "1.0 months", ["monthsValue"], false, false, false]);
}

// ---- S. A store's subscription history start is marked on the hero chart (B35 3.4) -----------------------------------------------
{
  const doc = mockActive({ tenantId: "t1", permissions: ["reports.view"] }, fromMonthOf("24", new Date().toISOString().slice(0, 10)), { market: null, segment: null, channel: null }, "month");
  const from = doc.months[0]?.month ?? "9999";
  const inside = doc.notes.historyStarts.filter((h) => h.date >= from);
  const page = src("app/reports/active/page.tsx");
  const charts = src("components/ActiveCharts.tsx");
  const seed = readFileSync(new URL("../../db/03_seed_dev_test_data.sql", import.meta.url), "utf8");
  expect("S1 the mock has a store whose history starts inside the default 24 months (the dev seed's second store too); the hero draws a marker for each",
    [doc.notes.historyStarts.length, inside.map((h) => h.store), doc.months.length >= 24, /markers=\{markers\}/.test(page), /data-testid="active-marker"/.test(charts),
      /fmtDate\(h\.date, locale, "full"\)/.test(page), /when i = 2 and 10 \+ \(g \* 53\) % 900 > 540 then 540/.test(seed)],
    [3, ["mock-gb"], true, true, true, true, true], [0, [], false, false, false, false, false]);
}

// ---- X. The placeholders render no digit --------------------------------------------------------------------------------------
{
  const words = (lang) => [...ACTIVE_SLOTS.flatMap((s) => [activeCopy[lang][`slot_${s.key}`], ...s.fedBy.map((f) => activeCopy[lang][`feed_${f}`])]),
    activeCopy[lang].notConnected, activeCopy[lang].fedBy, copy[lang].flash.status_Pending];
  const parts = src("components/ActiveParts.tsx");
  const card = parts.slice(parts.indexOf("export function PlaceholderCard"), parts.indexOf("/** A quiet note above a panel"));
  const doc = mockActive({ tenantId: "t1", permissions: ["reports.view"] }, null, { market: null, segment: null, channel: null }, "month");
  expect("X1 a placeholder's label, badge and sources hold no digit in en or nl; the card writes no number; the mock's slots carry a key and pending alone",
    [words("en").filter((w) => /\d/.test(w)), words("nl").filter((w) => /\d/.test(w)), /fmt|toFixed|\{n\(|value=/.test(card), /\d/.test(JSON.stringify(doc.unitEconomics.slots)),
      doc.unitEconomics.slots.map((s) => Object.keys(s).join(",")), doc.unitEconomics.slots.map((s) => s.status)],
    [[], [], false, false, Array(6).fill("key,status"), Array(6).fill("pending")], [["0"], ["0"], true, true, Array(6).fill("key,status,value"), Array(6).fill("0")]);
}

// ---- M. The mock's document ---------------------------------------------------------------------------------------------------
{
  const me = { tenantId: "t1", permissions: ["reports.view"] };
  const none = { market: null, segment: null, channel: null };
  const doc = mockActive(me, null, none, "month");
  const ms = doc.months;
  const broken = ms.filter((m, i) => m.net !== m.inflow - m.outflow || (i > 0 && !m.isNow && m.customers - ms[i - 1].customers !== m.net)).length;
  const last = ms[ms.length - 1];
  expect("M1 net change = inflow − outflow = this month end − the previous one; the running month is now and equals the headline",
    [ms.length > 12, broken, last.isNow, last.customers === doc.tiles.activeCustomers.value, last.subscriptions === doc.tiles.totalSubscriptions.value],
    [true, 0, true, true, true], [true, 1, false, false, false]);
  const sum = (key, values) => values.reduce((n, v) => n + mockActive(me, null, { ...none, [key]: v }, "month").tiles.activeCustomers.value, 0);
  expect("M2 the three channels, the segments and the markets each add up to the unfiltered active customers; the split lines too",
    [sum("channel", ACTIVE_CHANNELS) === doc.tiles.activeCustomers.value, sum("segment", doc.filters.segments) === doc.tiles.activeCustomers.value,
      sum("market", doc.filters.markets) === doc.tiles.activeCustomers.value, Object.values(doc.tiles.activeCustomers.byChannel).reduce((a, b) => a + b, 0) === doc.tiles.activeCustomers.value,
      doc.markets.reduce((n, m) => n + m.customers, 0) === doc.marketsTotal.customers],
    [true, true, true, true, true], [false, false, false, false, false]);
  expect("M3 three markets, two currencies never added up, both segments, the comparison's unknown beside; the euro line with its rates' date",
    [doc.filters.markets, doc.tiles.amounts.map((a) => a.currency), doc.comparison.a, doc.comparison.b, doc.comparison.rows.some((r) => r.currency === "GBP" && r.measure === "clv_average"),
      typeof doc.tiles.eur?.asOf, doc.comparison.rows.every((r) => r.difference === null || (r.a !== null && r.b !== null))],
    [["DE", "GB", "NL"], ["EUR", "GBP"], "B2B", "B2C", true, "string", true], [["NL"], ["EUR"], "B2C", "B2B", false, "undefined", false]);
  const two = mockActive({ tenantId: "00000000-0000-7000-8000-000000000002", permissions: ["reports.view"] }, null, none, "month");
  let refused = "ok";
  try {
    mockActive({ tenantId: "t1", permissions: ["time.own"] }, null, none, "month");
  } catch (e) {
    refused = e.sqlState;
  }
  expect("M4 a tenant without a store: not set up, no figure (never zeros); a person without the report permissions: refused (CMA06)",
    [two.figures, two.setUp, two.tiles, two.months.length, refused], [false, { commerce: false, subscriptions: false }, null, 0, "CMA06"], [true, { commerce: true, subscriptions: true }, {}, 1, "ok"]);
  expect("M5 the list: active customers only, sorted by the amount within its currency, 50 a page; the sort keys the database takes",
    (() => {
      const l = mockActiveRows(me, { filter: none, sort: "monthly_amount", descending: true, limit: 50 });
      const within = l.rows.every((r, i) => i === 0 || l.rows[i - 1].currency !== r.currency || (l.rows[i - 1].monthlyAmount ?? -1) >= (r.monthlyAmount ?? -1));
      return [l.rows.length, l.total === doc.tiles.activeCustomers.value, within, ACTIVE_SORTS.length];
    })(), [50, true, true, 12], [10, false, false, 3]);

  // ---- N. the stored take, the two reads and the list's cursors (addendum B: decisions D13 to D15) -------------------
  const top = activePartOf(doc, "top");
  const rest = activePartOf(doc, "rest");
  const back = mergeActive(top, rest);
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  expect("N1 the report in two reads: each answers its own part and leaves the other's empty (never a guess); the two together are the whole",
    [top.tiles !== null, top.markets.length, top.comparison, top.months.every((m) => m.inflow === 0 && Object.keys(m.amounts).length === 0),
      rest.tiles, rest.markets.length > 0, rest.months.every((m) => m.customers === 0 && m.subscriptions === 0),
      ["tiles", "unitEconomics", "months", "markets", "marketsTotal", "comparison", "survival", "ageBands", "cohorts", "cohortSplits", "mix", "notes"].filter((k) => !same(back[k], doc[k]))],
    [true, 0, null, true, null, true, true, []], [false, 3, {}, false, {}, false, false, ["tiles"]]);
  expect("N2 the take rides on every read: when the history was computed, never stale or late in the mock; without a store neither a take nor a history",
    [typeof doc.take?.computedAt, doc.take?.stale, doc.take?.late, doc.history, two.take, two.history], ["string", false, false, true, null, false],
    ["undefined", true, true, false, {}, true]);
  const pages = [];
  let page = mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7 });
  const firstPrev = page.prev;
  for (let guard = 0; guard < 500; guard += 1) {
    pages.push(page);
    if (!page.next) break;
    page = mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7, after: page.next });
  }
  const all = mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 200 });
  const chained = pages.flatMap((p) => p.rows.map((r) => r.storeCustomer));
  const beforeLast = pages.length > 1 ? mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7, before: pages[pages.length - 1].prev }) : null;
  let badCursor = "ok";
  try {
    mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7, after: "bm90IGEgY3Vyc29y" });
  } catch (e) {
    badCursor = e.sqlState;
  }
  let strangerCursor = "ok";
  try {
    mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7, after: "00000000-0000-4000-8000-00000fffffff" });
  } catch (e) {
    strangerCursor = e.sqlState;
  }
  expect("N3 keyset paging: pages chained by next hold every row once in order; the first has no prev, the last no next; prev leads back; a cursor is an id alone, one that is none is refused",
    [chained.length === all.total, same(chained.slice(0, 200), all.rows.map((r) => r.storeCustomer)), firstPrev, pages[pages.length - 1].next,
      beforeLast ? same(beforeLast.rows, pages[pages.length - 2].rows) : false, badCursor, strangerCursor, "offset" in (all ?? {}),
      pages.every((x) => (x.next === null || ACTIVE_CURSOR.test(x.next)) && (x.prev === null || ACTIVE_CURSOR.test(x.prev))),
      ACTIVE_CURSOR.test("bm90IGEgY3Vyc29y"), ACTIVE_CURSOR.test("eyJrIjpbXSwicyI6IjEifQ==")],
    [true, true, null, null, true, "CMA04", "CMA04", false, true, false, false], [false, false, "x", "x", false, "ok", "ok", true, false, true, true]);
  const pending = src("components/ActivePending.tsx");
  const pageSrc = src("app/reports/active/page.tsx");
  const clientFiles = ["components/ActiveFilters.tsx", "components/ActivePending.tsx"];
  expect("N4 the page's client code is the filters and one small component (D14): no fetch, no observer, no timer of its own; every sortable link and toggle carries the pending mark",
    [clientFiles.every((f) => src(f).startsWith('"use client"')), /\bfetch\(|XMLHttpRequest|IntersectionObserver|setInterval|setTimeout|EventSource|WebSocket/.test(pending),
      /useLinkStatus/.test(pending), (src("components/ActiveParts.tsx").match(/<LinkMark \/>/g) ?? []).length >= 6,
      ["components/ActiveCharts.tsx", "components/ActiveParts.tsx", "app/reports/active/page.tsx"].some((f) => src(f).startsWith('"use client"'))],
    [true, false, true, true, false], [false, true, false, false, true]);
  expect("N5 four streamed parts and a fixed height for every data panel (D15, D16): the page names each panel once, the Print button waits for all four parts",
    [ACTIVE_PARTS.join(","), Object.keys(ACTIVE_PANEL_HEIGHT).filter((id) => !new RegExp(`layer\\("${id}", "(top|rest|list)"\\)`).test(pageSrc)),
      Object.values(ACTIVE_PANEL_HEIGHT).every((h) => Number.isInteger(h) && h > 0), /PrintWhenReady[^>]*parts=\{ACTIVE_PARTS\}/.test(pageSrc),
      ["top", "rest", "list"].every((part) => new RegExp(`layer\\("[a-zA-Z]+", "${part}"\\)\\} read=\\{[a-zA-Z]+\\} mark`).test(pageSrc)),
      /<Streamed part="now" view=\{ctx\.viewKey\} \/>/.test(pageSrc), ACTIVE_SCROLLING.every((id) => id in ACTIVE_PANEL_HEIGHT)],
    ["top,now,rest,list", [], true, true, true, true, true], ["top", ["tiles"], false, false, false, false, false]);

  // ---- O. the table first, the live present after (decision D16) ---------------------------------------------------------
  const live = mockActiveNow(me, none);
  const moved = { ...live, computedAt: "2031-01-01T00:00:00.000Z", now: { ...live.now, customers: live.now.customers + 3, subscriptions: 1 },
    tiles: { ...live.tiles, activeCustomers: { ...live.tiles.activeCustomers, value: live.tiles.activeCustomers.value + 3 }, totalSubscriptions: { ...live.tiles.totalSubscriptions, value: 1 } } };
  const merged = withActiveNow(top, moved);
  expect("O1 the live present takes the places of the four tiles that state it and nothing else: the take's own tiles, the series and the take stay; its moment is said",
    [merged.tiles.activeCustomers.value - top.tiles.activeCustomers.value, merged.tiles.totalSubscriptions.value, same(merged.tiles.customerAge, top.tiles.customerAge),
      same(merged.tiles.lifetime, top.tiles.lifetime), same(merged.tiles.clv, top.tiles.clv),
      // the series: only its running point moves, to the live headline; the note on the reconstruction's difference with it
      same(merged.months.filter((m) => !m.isNow), top.months.filter((m) => !m.isNow)) && merged.months.find((m) => m.isNow).customers === moved.now.customers
        && merged.notes.reconstructionGap - top.notes.reconstructionGap === top.months.find((m) => m.isNow).customers - moved.now.customers, same(merged.take, top.take),
      top.presentAt === top.take.computedAt, merged.presentAt, same(withActiveNow(top, null), top), same(withActiveNow(top, { figures: true, computedAt: "x", tiles: null, now: null }), top),
      Object.keys(live.tiles).sort().join(","), same(activeNowFromDb({ figures: true, computed_at: "t", tiles: { active_customers: { value: 4, by_segment: { B2B: 4 }, by_channel: null } } }),
        { figures: true, source: "live", computedAt: "t", tiles: { activeCustomers: { value: 4, bySegment: { B2B: 4 }, byChannel: null } }, now: null })],
    [3, 1, true, true, true, true, true, true, "2031-01-01T00:00:00.000Z", true, true, "activeCustomers,amounts,eur,totalSubscriptions", true],
    [0, 0, false, false, false, false, false, false, "", false, false, "", false]);
  const noTake = activeInTakeState(top, "none");
  const noTakeNow = activeNowInTakeState(live, "none", null);
  const noTakeView = withActiveNow(noTake, noTakeNow);
  const staleTop = activeInTakeState(top, "stale");
  const lateTop = activeInTakeState(top, "late");
  expect("O2 without a take nothing is a zero: the stored answer holds no tile, no churn count and no month, the filters' choices stay; the live present has no split by channel, and none under a channel filter",
    [noTake.history, noTake.take, noTake.tiles, noTake.unitEconomics, noTake.months.length, noTake.filters.markets.length > 0, noTake.presentAt,
      noTakeView.tiles.activeCustomers.value > 0, noTakeView.tiles.activeCustomers.byChannel, noTakeView.tiles.customerAge, noTakeView.tiles.lifetime, noTakeView.tiles.clv,
      activeNowInTakeState(live, "none", "direct").tiles, same(withActiveNow(noTake, activeNowInTakeState(live, "none", "direct")), noTake),
      activeListInTakeState(mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7 }), "none").total,
      activeListInTakeState(mockActiveRows(me, { filter: none, sort: "store_customer", descending: false, limit: 7 }), "none").rows.length,
      same(activeInTakeState(two, "none"), two)],
    [false, null, null, null, 0, true, null, true, null, null, null, null, null, true, null, 0, true],
    [true, {}, {}, {}, 1, false, "", false, {}, {}, {}, {}, {}, false, 0, 1, false]);
  expect("O3 a stale take and a late one say so and keep their figures; the stored tiles are of the take's moment",
    [staleTop.take.stale, staleTop.take.late, lateTop.take.stale, lateTop.take.late, lateTop.take.ageMinutes, same(staleTop.tiles, top.tiles), same(lateTop.months, top.months),
      lateTop.presentAt === lateTop.take.computedAt, same(activeInTakeState(top, null), top)],
    [true, true, false, true, 20, true, true, true, true], [false, false, true, false, 0, false, false, false, false]);
  const copySrc = src("lib/copy.ts");
  expect("O4 the frame reads nothing from the database (D15): no awaited read before the page returns; the filters and the comparison's title wait for the stored answer in their own slots; the live tiles' boundary is a new one on every view",
    [/await (Promise\.all\(\[)?data\(\)\./.test(pageSrc.slice(0, pageSrc.indexOf("function viewOf("))), /getActiveMarkets|listSettings/.test(pageSrc),
      /<Suspense fallback=\{<FiltersOutline t=\{t\} \/>\}>/.test(pageSrc), /<ComparisonTitle ctx=\{ctx\} read=\{topRead\} \/>/.test(pageSrc),
      /<Suspense key=\{`now\|\$\{ctx\.viewKey\}`\} fallback=\{<PresentTiles ctx=\{ctx\} top=\{top\} settled=\{false\} \/>\}>/.test(pageSrc),
      /dataIsMock && \(ACTIVE_TAKE_STATES/.test(pageSrc), ["tilesAsOf", "historyStaleBody", "comparisonCardPlain", "printLoading"].every((k) => (copySrc.match(new RegExp(`\\b${k}: "`, "g")) ?? []).length === 2)],
    [false, false, true, true, true, true, true], [true, true, false, false, false, false, false]);
}

// ---- addition 0009n: the present's source, and the attribution's note on both pages ---------------------------------------
{
  const pageSrc = src("app/reports/active/page.tsx");
  const partsSrc = src("components/FirstOrderParts.tsx");
  const sentence = (lang, where) => (where === "active" ? activeCopy[lang].noteAttributionStart : copy[lang].firstOrders.historyMeaning);
  expect("O5 the present says where it was read from: the take's answer is 'As of' the take's moment, the live one 'Updated'; an answer without the key is live",
    [activeNowFromDb({ figures: true, source: "take", computed_at: "t" }).source, activeNowFromDb({ figures: true, source: "live", computed_at: "t" }).source,
      activeNowFromDb({ figures: true, computed_at: "t" }).source, mockActiveNow({ tenantId: "t1", permissions: ["reports.view"] }, { market: null, segment: null, channel: null }).source,
      /now\.source === "take"\s*\? <span data-testid="active-updated" data-present="take" data-old=\{old \? "" : undefined\}>\{ctx\.t\.tilesFromTake/.test(pageSrc),
      /dataIsMock && view\.present === "take"/.test(pageSrc), activeCopy.en.tilesFromTake, activeCopy.nl.tilesFromTake,
      // hours and minutes, and the take's date beside them when the take is not of today; the API's answer says the source
      /const old = takenOn !== ctx\.today;/.test(pageSrc) && /old \? `\$\{fmtDate\(takenOn, ctx\.me\.locale, "compact"\)\}, \$\{clock\(ctx\.me, now\.computedAt\)\}` : clock\(ctx\.me, now\.computedAt\)/.test(pageSrc),
      /presentAt: now\.computedAt, presentSource: now\.source,/.test(src("lib/active.ts")),
      activeCopy.en.reason_before_history, activeCopy.nl.reason_before_history],
    ["take", "live", "live", "live", true, true, "As of {time}", "Per {time}", true, true, "Started before the first order deal on record", "Gestart vóór de eerste bekende besteldeal"],
    ["", "", "", "", false, false, "", "", false, false, "", ""]);
  expect("O6 the attribution's note says what its date means, in the same sentence on Customers → Active and on Sales → First orders, in both languages, each page with its own two words",
    [sentence("en", "active") === sentence("en", "first"), sentence("nl", "active") === sentence("nl", "first"),
      ["{date}", "{direct}", "{indirect}"].every((k) => sentence("en", "active").includes(k) && sentence("nl", "active").includes(k)),
      /intake start/.test(sentence("en", "active")), /replace\("\{direct\}", t\.channelShort_direct\)\.replace\("\{indirect\}", t\.channelShort_indirect\)/.test(pageSrc),
      partsSrc.includes('t.historyMeaning.replace("{date}", fmtDate(historyStart, locale)).replace("{direct}", t.selfService.toLowerCase()).replace("{indirect}", t.callCenter.toLowerCase())'),
      /notes\.unknownChannel\.customers > 0 \|\| rest\.settings\.attribution\.historyStart/.test(pageSrc)],
    [true, true, true, true, true, true, true], [false, false, false, false, false, false, false]);
}

const n = results.length;
const passed = results.filter(Boolean).length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
}
console.log(`\n${passed === n ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
process.exit(passed === n ? 0 : 1);
