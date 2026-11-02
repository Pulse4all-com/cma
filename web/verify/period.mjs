/**
 * Verifier: the shared period bar (src/lib/period.ts, src/components/PeriodBar.tsx), without a browser or a database.
 *
 *   node --experimental-strip-types verify/period.mjs             every check must PASS
 *   node --experimental-strip-types verify/period.mjs --provoke   every check must FAIL
 *
 * Since 26 October 2026 (Yesterday on the period bar): Yesterday as the day before today across a month and a
 * year end, the default and an unknown range still Today, the order and the letters of the five choices with no
 * letter twice, every page with the period bar rendering it, no page or component branching on a range other
 * than the custom one; Reports → Calls with range=yesterday as an ended period (README Decision log, 14 October
 * 2026): the whole day before, "vs the previous period" in both languages, a late call on the day before counted
 * whatever the time now, where Today cuts it; and on Reports → Forms no shortcut letter twice among the page's own
 * controls, Category on A with its keycap, the filters clear of the shell's letters, and the period bar meeting the
 * shell only on the two letters the shortcut hook gives the page (W, C).
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { copy } from "../src/lib/copy.ts";
import { MAX_DIGIT_KEYS, navEntries } from "../src/lib/nav.ts";
import { RANGE_KEYS, RANGES, resolvePeriod } from "../src/lib/period.ts";
import { callRecords, callRules, callsFigures, fmtShare, MAX_REPORT_DAYS, previousCalls, previousLabel, previousPeriod } from "../src/lib/reports.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(58)} got ${JSON.stringify(actual).slice(0, 70)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 70)}`}`);
}
const src = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const dupes = (letters) => [...new Set(letters.filter((k, i) => letters.indexOf(k) !== i))];

// ---- the period from the query string ----------------------------------------------------------
const at = (range, today) => resolvePeriod(range === undefined ? {} : { range }, today, MAX_REPORT_DAYS);
expect("yesterday: the day before, across a month end, a year end and 29 February",
  [at("yesterday", "2026-11-01"), at("yesterday", "2027-01-01").period, at("yesterday", "2026-10-26").period, at("yesterday", "2028-03-01").period],
  [{ range: "yesterday", period: { from: "2026-10-31", to: "2026-10-31" }, invalid: null }, { from: "2026-12-31", to: "2026-12-31" },
    { from: "2026-10-25", to: "2026-10-25" }, { from: "2028-02-29", to: "2028-02-29" }],
  [{ range: "today", period: { from: "2026-11-01", to: "2026-11-01" }, invalid: null }, { from: "2027-01-01", to: "2027-01-01" },
    { from: "2026-10-26", to: "2026-10-26" }, { from: "2028-02-28", to: "2028-02-28" }]);
expect("without a range, or with one it does not know, the period is today",
  [undefined, "", "Yesterday", "y", "Y", "tomorrow", "yesterday "].map((r) => `${at(r, "2026-11-01").range} ${at(r, "2026-11-01").period.from}`)
    .concat(`${resolvePeriod({ range: ["yesterday"] }, "2026-11-01").range}`),
  ["today 2026-11-01", "today 2026-11-01", "today 2026-11-01", "today 2026-11-01", "today 2026-11-01", "today 2026-11-01", "today 2026-11-01", "today"],
  ["yesterday 2026-10-31", "today 2026-11-01", "yesterday 2026-10-31", "yesterday 2026-10-31", "yesterday 2026-10-31", "today 2026-11-01", "yesterday 2026-10-31", "yesterday"]);
expect("the other choices unchanged: today, the ISO week, the month, a custom range",
  ["today", "week", "month"].map((r) => at(r, "2026-11-01").period).concat(resolvePeriod({ range: "custom", from: "2026-10-01", to: "2026-10-05" }, "2026-11-01").period),
  [{ from: "2026-11-01", to: "2026-11-01" }, { from: "2026-10-26", to: "2026-11-01" }, { from: "2026-11-01", to: "2026-11-30" }, { from: "2026-10-01", to: "2026-10-05" }],
  [{ from: "2026-10-31", to: "2026-10-31" }, { from: "2026-10-26", to: "2026-11-01" }, { from: "2026-11-01", to: "2026-11-30" }, { from: "2026-10-01", to: "2026-10-05" }]);

// ---- the bar: order, letters, labels ----------------------------------------------------------
const keys = RANGES.map((r) => RANGE_KEYS[r]);
expect("the bar's order: Yesterday first, then Today, week, month, custom",
  [RANGES, keys.join("")], [["yesterday", "today", "week", "month", "custom"], "YTWMC"], [["today", "week", "month", "custom"], "TWMC"]);
expect("RANGE_KEYS: one capital letter per choice, no letter twice, every choice on the bar",
  [dupes(Object.values(RANGE_KEYS)), Object.values(RANGE_KEYS).every((k) => /^[A-Z]$/.test(k)), Object.keys(RANGE_KEYS).sort().join(",") === [...RANGES].sort().join(",")],
  [[], true, true], [["Y"], false, false]);
const barSource = src("../src/components/PeriodBar.tsx");
expect("the bar labels Yesterday from the copy, in both languages, and binds each letter",
  [copy.en.myHours.yesterday, copy.nl.myHours.yesterday, barSource.includes("yesterday: copy.myHours.yesterday"),
    barSource.includes("data-shortcut={RANGE_KEYS[k].toLowerCase()}") && barSource.includes("<Keycap>{RANGE_KEYS[k]}</Keycap>")],
  ["Yesterday", "Gisteren", true, true], ["Today", "Vandaag", false, false]);

// ---- every page with the period bar ------------------------------------------------------------
const pathnames = [...barSource.match(/pathname:\s*([^;]+);/)[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
const pageFile = (p) => `../src/app${p}/page.tsx`;
const rendering = pathnames.filter((p) => {
  const page = src(pageFile(p));
  return page.includes("resolvePeriod(sp, today") && new RegExp(`<PeriodBar\\s+pathname="${p}"`).test(page);
});
expect("all 19 pages with the period bar resolve their period and render the shared bar",
  [pathnames.length, rendering.length], [19, 19], [18, 18]);
// The like-for-like path follows the dates (previousPeriod: to >= today), never the range: a page or component that
// compared range with "yesterday", "today", "week" or "month" would put Yesterday on the wrong path
function files(dir) {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? files(p) : /\.tsx?$/.test(f) ? [p] : [];
  });
}
const root = new URL("../src/", import.meta.url).pathname;
const branching = files(root).filter((f) => /\brange\s*[!=]==?\s*"(yesterday|today|week|month)"|"(yesterday|today|week|month)"\s*[!=]==?\s*range\b/.test(readFileSync(f, "utf8")))
  .map((f) => f.slice(root.length));
expect("no page or component branches on a range but custom", branching, [], ["app/hours/page.tsx"]);
// Y reaches Yesterday on every page: no other control in the app binds it, inside main or in the shell
const otherY = files(root).filter((f) => /data-shortcut=(?:"y"|\{[^}]*"y"[^}]*\})/.test(readFileSync(f, "utf8"))).map((f) => f.slice(root.length));
expect("no other control in the app binds Y", otherY, [], ["components/FormsFilters.tsx"]);

// ---- Reports → Calls with range=yesterday: an ended period ------------------------------------
const TODAY = "2026-11-01";
const y = at("yesterday", TODAY).period;
const prevY = previousPeriod(y, TODAY);
const prevT = previousPeriod(at("today", TODAY).period, TODAY);
expect("yesterday compares with the whole day before; today with the same point",
  [prevY, prevT], [{ from: "2026-10-30", to: "2026-10-30", partial: false }, { from: "2026-10-31", to: "2026-10-31", partial: true }],
  [{ from: "2026-10-30", to: "2026-10-30", partial: true }, { from: "2026-10-31", to: "2026-10-31", partial: false }]);
// the delta's words as DeltaLine writes them: the change, then what it compares with; the day as the title, not cut
const delta = (locale, p) => {
  const label = previousLabel(p.from, p.to, p.partial, copy[locale], locale);
  return [copy[locale].calls.deltaUp.replace("{pct}", fmtShare(0.25, locale)).replace("{previous}", label.text), label.dates];
};
expect("Calls, range=yesterday: \"vs the previous period\", the day before as the title",
  [...delta("en", prevY), ...delta("nl", prevY)],
  ["↑ 25% vs the previous period", "30 Oct", "↑ 25% t.o.v. de vorige periode", "30 okt"],
  ["↑ 25% vs the same point in the previous period", "30 Oct, the last day up to the current time",
    "↑ 25% t.o.v. hetzelfde punt in de vorige periode", "30 okt, de laatste dag tot het huidige tijdstip"]);
// Two calls on the day before yesterday in Amsterdam: 08:00 and 23:30. Asked at 09:00 on 1 November, yesterday
// counts both (the whole day), today's previous day only the one before 09:00
const CONN = "00000000-0000-7000-8000-0000000000c1";
const lines = [{ connectionId: CONN, lineRef: "line-nl", name: "Verify NL line", market: "NL", zone: "Europe/Amsterdam", isCounted: true }];
const call = (src, startIso, endSeconds) => ({
  sourceId: src, connectionId: CONN, sourceSystem: "verifytel", direction: "inbound", startedAt: startIso,
  answeredAt: new Date(Date.parse(startIso) + 5000).toISOString(), endedAt: new Date(Date.parse(startIso) + endSeconds * 1000).toISOString(),
  missedReason: null, lineRef: "line-nl", userRef: null, tagRefs: [],
});
const calls = callRecords([call("p1", "2026-10-30T07:00:00Z", 65), call("p2", "2026-10-30T22:30:00Z", 125),
  call("t1", "2026-10-31T07:00:00Z", 65), call("t2", "2026-10-31T22:30:00Z", 125)], lines, "Europe/Amsterdam", callRules(10, 0, []));
const NOW = "2026-11-01T08:00:00Z";
expect("Calls, range=yesterday: a late call on the day before counts whatever the time now",
  [callsFigures(previousCalls(calls, prevY, NOW)).calls, callsFigures(previousCalls(calls, prevT, NOW)).calls], [2, 1], [1, 1]);

// ---- Reports → Forms: no letter twice ---------------------------------------------------------
const formsPage = src("../src/app/reports/forms/page.tsx");
const lettersIn = (text) => [...text.matchAll(/data-shortcut=(?:"([^"]+)"|\{([^}]*)\})/g)]
  .flatMap((m) => (m[1] !== undefined ? [m[1]] : [...m[2].matchAll(/"([^"]+)"/g)].map((x) => x[1])));
// The body of one exported function, up to the next export
const fnBody = (text, name) => {
  const start = text.search(new RegExp(`export function ${name}\\b`));
  if (start < 0) return "";
  const next = text.slice(start + 1).search(/\nexport /);
  return next < 0 ? text.slice(start) : text.slice(start, start + 1 + next);
};
// The components the page imports, each with the letters its own body binds; the period bar's come from RANGE_KEYS
const used = [...formsPage.matchAll(/import \{([^}]+)\} from "@\/components\/([A-Za-z]+)"/g)]
  .flatMap((m) => m[1].split(",").map((s) => s.trim()).filter((s) => /^[A-Z]/.test(s)).map((name) => ({ name, file: m[2] })));
const pageLetters = (provokeCategory) => [
  ...lettersIn(formsPage),
  ...used.flatMap(({ name, file }) => name === "PeriodBar" ? keys.map((k) => k.toLowerCase())
    : name === "Shell" ? [] : lettersIn(fnBody(src(`../src/components/${file}.tsx`), name))),
  ...(provokeCategory ? ["y"] : []),
].sort();
const filtersSource = src("../src/components/FormsFilters.tsx");
const filterLetters = lettersIn(fnBody(filtersSource, "FormsFilters"));
expect("Forms: every letter of the page's own controls once",
  [pageLetters(false).join(""), dupes(pageLetters(false))], ["acfgkmtwxy", []], ["acfgkmtwxyy", ["y"]]);
expect("Forms: Category answers to A, with its keycap",
  [filterLetters, [...fnBody(filtersSource, "FormsFilters").matchAll(/<Keycap>([^<]+)<\/Keycap>/g)].map((m) => m[1].toLowerCase()),
    /data-shortcut="a" data-testid="forms-category"/.test(filtersSource)],
  [["k", "a", "f"], ["k", "a", "f"], true], [["k", "y", "f"], ["k", "y", "f"], false]);
// The shell's letters: Log out, the rail's digits and group letters, the rail toggle and the hints toggle. The urgent
// message's A (MessageCenter) is not among them: it renders only inside its open dialog, where the hook counts the
// dialog's own shortcuts alone
const shellLetters = [
  ...lettersIn(src("../src/components/Shell.tsx")),
  ...Array.from({ length: MAX_DIGIT_KEYS }, (_, i) => String(i + 1)),
  ...navEntries(copy.en).flatMap((e) => (e.kind === "group" && e.shortcut ? [e.shortcut] : [])),
  ...lettersIn(src("../src/components/ShellPrefs.tsx")),
];
const barLetters = keys.map((k) => k.toLowerCase());
const ownLetters = pageLetters(false).filter((k) => !barLetters.includes(k));
expect("Forms: the filters, grouping and download clear of the shell's letters",
  ownLetters.filter((k) => shellLetters.includes(k)), [], ["c"]);
// The hook gives a control inside main the letter first: This week over the rail toggle (W) and Custom range over
// the Configuration group (C) are known and yield to the page; Yesterday's Y meets nothing in the shell
expect("Forms: the period bar meets the shell only on W and C, which the page wins",
  barLetters.filter((k) => shellLetters.includes(k)).sort(), ["c", "w"], ["c", "w", "y"]);

const passed = results.filter(Boolean).length;
const n = results.length;
if (PROVOKE) {
  const ok = passed === 0;
  console.log(`\n${ok ? `ALL ${n} PROVOKED CHECKS FAILED, as they must` : `${passed} of ${n} checks did not fail when provoked`}`);
  process.exit(ok ? 0 : 1);
} else {
  const ok = passed === n;
  console.log(`\n${ok ? `ALL ${n} PASS` : `${n - passed} of ${n} FAILED`}`);
  process.exit(ok ? 0 : 1);
}
