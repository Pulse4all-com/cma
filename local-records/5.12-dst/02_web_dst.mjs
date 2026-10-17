// 5.12 DST readiness: the web helpers around 2026-10-25 Europe/Amsterdam, run under Node 22 type stripping.
// Run from web/:  node --experimental-strip-types --disable-warning=MODULE_TYPELESS_PACKAGE_JSON ../local-records/5.12-dst/02_web_dst.mjs
import { dateKeyInZone, addDays, daysBetween, startOfWeek, endOfMonth, hourInZone, fmtTime, fmtZoneShort, sameOffset } from "../../web/src/lib/time.ts";
import { instantsForLocal } from "../../web/src/lib/corrections.ts";
import { plannedInstant, shiftMinutes, adherence, weekDays, isoWeek } from "../../web/src/lib/roster.ts";
import { workedSeconds, secondsSince, fmtSeconds } from "../../web/src/lib/live.ts";

const Z = "Europe/Amsterdam";
const iso = (ms) => (ms === null ? null : new Date(ms).toISOString());
const out = (name, value) => console.log(`${name.padEnd(70)} ${JSON.stringify(value)}`);

console.log("process TZ:", process.env.TZ ?? "(unset: host default)", "| Intl default:", Intl.DateTimeFormat().resolvedOptions().timeZone);
console.log("\n-- time.ts: date keys in a zone around the 25-hour day");
out("dateKeyInZone 2026-10-24T21:59:59Z", dateKeyInZone("2026-10-24T21:59:59Z", Z));
out("dateKeyInZone 2026-10-24T22:00:00Z (00:00 CEST)", dateKeyInZone("2026-10-24T22:00:00Z", Z));
out("dateKeyInZone 2026-10-25T22:59:59Z (23:59:59 CET)", dateKeyInZone("2026-10-25T22:59:59Z", Z));
out("dateKeyInZone 2026-10-25T23:00:00Z (00:00 CET 26th)", dateKeyInZone("2026-10-25T23:00:00Z", Z));
out("addDays 2026-10-24 +1 / 2026-10-25 +1 (UTC date arithmetic)", [addDays("2026-10-24", 1), addDays("2026-10-25", 1)]);
out("daysBetween 2026-10-19..2026-10-25 / 2026-10-25..2026-10-26", [daysBetween("2026-10-19", "2026-10-25"), daysBetween("2026-10-25", "2026-10-26")]);
out("startOfWeek 2026-10-25 (Sunday) / endOfMonth", [startOfWeek("2026-10-25"), endOfMonth("2026-10-25")]);
out("hourInZone 2026-10-25T00:30Z / 01:30Z (both 02:xx local)", [hourInZone("2026-10-25T00:30:00Z", Z), hourInZone("2026-10-25T01:30:00Z", Z)]);
out("fmtTime 00:30Z / 01:30Z en (both read 02:30)", [fmtTime("2026-10-25T00:30:00Z", Z, "en"), fmtTime("2026-10-25T01:30:00Z", Z, "en")]);
out("fmtZoneShort 00:30Z / 01:30Z", [fmtZoneShort("2026-10-25T00:30:00Z", Z, "en"), fmtZoneShort("2026-10-25T01:30:00Z", Z, "en")]);
out("sameOffset Amsterdam/Madrid at 01:30Z; Amsterdam/London", [sameOffset("2026-10-25T01:30:00Z", Z, "Europe/Madrid"), sameOffset("2026-10-25T01:30:00Z", Z, "Europe/London")]);
out("period.ts week for today=2026-10-25 (startOfWeek..+6, as resolvePeriod builds it)", [startOfWeek("2026-10-25"), addDays(startOfWeek("2026-10-25"), 6)]);

console.log("\n-- corrections.ts: the instants of a local time (Day editor)");
out("instantsForLocal 2026-10-25 02:30", instantsForLocal("2026-10-25", "02:30", Z).map((x) => x.at));
out("instantsForLocal 2026-10-25 07:00 / 22:00", [instantsForLocal("2026-10-25", "07:00", Z).map((x) => x.at), instantsForLocal("2026-10-25", "22:00", Z).map((x) => x.at)]);
out("instantsForLocal 2026-03-29 02:30 (skipped hour)", instantsForLocal("2026-03-29", "02:30", Z).map((x) => x.at));

console.log("\n-- roster.ts: planned shift of 2026-10-25 as instants, planned minutes, adherence");
out("plannedInstant 07:00 / 22:00 / 24:00", [iso(plannedInstant("2026-10-25", "07:00", Z)), iso(plannedInstant("2026-10-25", "22:00", Z)), iso(plannedInstant("2026-10-25", "24:00", Z))]);
out("shiftMinutes 07:00-22:00 vs instants span (min)", [shiftMinutes("07:00", "22:00"), (plannedInstant("2026-10-25", "22:00", Z) - plannedInstant("2026-10-25", "07:00", Z)) / 60000]);
out("shiftMinutes 01:00-04:00 vs instants span (hypothetical night shift)", [shiftMinutes("01:00", "04:00"), (plannedInstant("2026-10-25", "04:00", Z) - plannedInstant("2026-10-25", "01:00", Z)) / 60000]);
out("plannedInstant 02:30 picks the earlier instant", iso(plannedInstant("2026-10-25", "02:30", Z)));
const planned = { kind: "shift", start: "07:00", end: "22:00" };
out("adherence: in 07:03 CET, now 12:00 CET -> onTime", adherence(planned, { startedAt: "2026-10-25T06:03:00Z", endedAt: null }, "2026-10-25", Z, Date.parse("2026-10-25T11:00:00Z"), 5));
out("adherence: in 07:06 CET -> late", adherence(planned, { startedAt: "2026-10-25T06:06:00Z", endedAt: null }, "2026-10-25", Z, Date.parse("2026-10-25T11:00:00Z"), 5));
out("adherence: out 21:50 CET -> leftEarly", adherence(planned, { startedAt: "2026-10-25T06:00:00Z", endedAt: "2026-10-25T20:50:00Z" }, "2026-10-25", Z, Date.parse("2026-10-25T21:00:00Z"), 5));
out("adherence: out 21:56 CET -> onTime (within tolerance)", adherence(planned, { startedAt: "2026-10-25T06:00:00Z", endedAt: "2026-10-25T20:56:00Z" }, "2026-10-25", Z, Date.parse("2026-10-25T21:00:00Z"), 5));
out("weekDays 2026-10-19 / isoWeek 2026-10-25", [weekDays("2026-10-19"), isoWeek("2026-10-25")]);

console.log("\n-- live.ts: the ticking clock is instant arithmetic (closedSeconds from the server + now - runningSince)");
const clock = { closedSeconds: 3600, runningSince: "2026-10-25T00:30:00Z" }; // running since 02:30 CEST
out("workedSeconds at 02:30 CET (01:30Z): 3600 + 3600", workedSeconds(clock, Date.parse("2026-10-25T01:30:00Z")));
out("workedSeconds at 03:30 CET (02:30Z): 3600 + 7200", workedSeconds(clock, Date.parse("2026-10-25T02:30:00Z")));
out("workedSeconds capped by dayEndsAt 2026-10-25T21:00:00Z at 22:30 CET", workedSeconds({ closedSeconds: 0, runningSince: "2026-10-25T06:00:00Z" }, Date.parse("2026-10-25T21:30:00Z"), "2026-10-25T21:00:00Z"));
out("secondsSince 00:30Z at 01:30Z / fmtSeconds(54000)", [secondsSince("2026-10-25T00:30:00Z", Date.parse("2026-10-25T01:30:00Z")), fmtSeconds(54000)]);
