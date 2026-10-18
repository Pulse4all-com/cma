/**
 * Verifier: System health's logic (src/lib/health.ts), without a browser or a database.
 *
 *   node --experimental-strip-types verify/health.mjs             every check must PASS
 *   node --experimental-strip-types verify/health.mjs --provoke   every check must FAIL
 *
 * Covers the heartbeat state from an age against the tenant's thresholds (fresh, late, silent, none; the
 * defaults only where a setting is missing or unreadable), the latest heartbeat run, a job's state (ok,
 * failed, running, stuck past the task timeout, never), a connection's state from its jobs and events
 * (off, failing, attention, ok) as derived figures and never a live ping, the probe's state, the grouping
 * of runs per job in the page's order, and the documents: only an allowlisted plain name is a document
 * name (a separator, a dot-dot, a traversal, an empty or over-long name, a name outside the list refused),
 * the manifest parsed shape by shape (a bad hash, a name outside the list or a missing field refuses the
 * whole manifest), the entry lookup and the content types.
 */
import {
  DOCUMENT_ALLOWLIST, HEARTBEAT_FRESH_SECONDS_DEFAULT, HEARTBEAT_LATE_SECONDS_DEFAULT, JOB_ORDER, RUNNING_TOO_LONG_SECONDS,
  ageSeconds, connectionState, documentContentType, documentEntry, heartbeatRun, heartbeatState, heartbeatThresholds,
  isDocumentName, jobState, parseManifest, probeState, runDurationMs, runsByJob,
} from "../src/lib/health.ts";

const PROVOKE = process.argv.includes("--provoke");
const results = [];
function expect(name, actual, expected, provoked) {
  const want = PROVOKE ? provoked : expected;
  const pass = JSON.stringify(actual) === JSON.stringify(want);
  results.push(pass);
  console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(64)} got ${JSON.stringify(actual).slice(0, 60)}${pass ? "" : `, wanted ${JSON.stringify(want).slice(0, 60)}`}`);
}

const NOW = Date.parse("2026-10-17T12:00:00.000Z");
const at = (secondsAgo) => new Date(NOW - secondsAgo * 1000).toISOString();
const run = (job, connectionId, lastStatus, startedAgo, finishedAgo, extra = {}) => ({
  job, connectionId, lastStartedAt: at(startedAgo), lastFinishedAt: finishedAgo === null ? null : at(finishedAgo), lastStatus,
  lastError: lastStatus === "failed" ? "verify_code" : null, lastCounts: {},
  lastSucceededAt: lastStatus === "succeeded" ? at(finishedAgo ?? startedAgo) : null, lastFailedAt: lastStatus === "failed" ? at(finishedAgo ?? startedAgo) : null,
  lastFailedError: lastStatus === "failed" ? "verify_code" : null, runs24h: 1, failed24h: lastStatus === "failed" ? 1 : 0, ...extra,
});

// Thresholds: the settings win, the defaults cover a missing or unreadable key
expect("thresholds from settings", heartbeatThresholds([{ key: "health.heartbeat_fresh_seconds", value: "180" }, { key: "health.heartbeat_late_seconds", value: "1200" }]),
  { freshSeconds: 180, lateSeconds: 1200 }, { freshSeconds: 120, lateSeconds: 900 });
expect("thresholds default without settings", heartbeatThresholds([]),
  { freshSeconds: HEARTBEAT_FRESH_SECONDS_DEFAULT, lateSeconds: HEARTBEAT_LATE_SECONDS_DEFAULT }, { freshSeconds: 0, lateSeconds: 0 });
expect("thresholds default on an unreadable value", heartbeatThresholds([{ key: "health.heartbeat_fresh_seconds", value: "two minutes" }]).freshSeconds, 120, 0);

// Ages and heartbeat states
const T = { freshSeconds: 120, lateSeconds: 900 };
expect("age in whole seconds, never negative", [ageSeconds(at(61.9), NOW), ageSeconds(at(-30), NOW), ageSeconds(null, NOW), ageSeconds("not a time", NOW)], [61, 0, null, null], [62, -30, 0, 0]);
expect("heartbeat fresh below the first threshold", heartbeatState(119, T), "fresh", "late");
expect("heartbeat late from the first threshold", heartbeatState(120, T), "late", "fresh");
expect("heartbeat late below the second", heartbeatState(899, T), "late", "silent");
expect("heartbeat silent from the second threshold", heartbeatState(900, T), "silent", "late");
expect("heartbeat none without a run", heartbeatState(null, T), "none", "silent");
const runs = [
  run("link_calls", "c1", "succeeded", 50, 49),
  run("link_calls", "c1", "succeeded", 110, 109),
  run("forms_poll", "c1", "failed", 30, 29),
  run("email_poll", "c1", "succeeded", 40, 39, { failed24h: 1 }),
  run("close_forgotten_workdays", null, "succeeded", 1800, 1799),
  run("backfill", "c2", "running", 20 * 60, null),
  run("reconcile", "c3", "succeeded", 3600, 3500),
  run("reconcile", "c4", "failed", 3600, 3500, { lastSucceededAt: null }),
];
expect("the latest heartbeat run", heartbeatRun(runs)?.lastStartedAt, at(50), at(110));
expect("no heartbeat run", heartbeatRun(runs.filter((r) => r.job !== "link_calls")), null, {});

// Job states
expect("job ok", jobState(runs[0], NOW), "ok", "failed");
expect("job failed", jobState(runs[2], NOW), "failed", "ok");
expect("job running", jobState(run("backfill", "c2", "running", 60, null), NOW), "running", "stuck");
expect("job stuck past the task timeout", jobState(run("backfill", "c2", "running", RUNNING_TOO_LONG_SECONDS + 1, null), NOW), "stuck", "running");
expect("job never without a row", jobState(null, NOW), "never", "ok");
expect("a run's duration", [runDurationMs(runs[6]), runDurationMs(runs[5])], [100000, null], [100, 0]);

// Connection states
const src = (id, over = {}) => ({ id, isActive: true, events24h: 10, eventsWaiting: 0, eventsParked: 0, lastEventAt: at(60), ...over });
expect("connection off when switched off", connectionState(src("c1", { isActive: false }), runs, NOW), "off", "ok");
expect("connection failing on a failed last run", connectionState(src("c1"), runs, NOW), "failing", "ok");
expect("connection failing on a stuck run", connectionState(src("c2"), runs, NOW), "failing", "ok");
expect("connection failing when a job never succeeded", connectionState(src("c4"), runs, NOW), "failing", "attention");
expect("connection attention on parked events", connectionState(src("c3", { eventsParked: 2 }), runs, NOW), "attention", "ok");
expect("connection attention on a failure in 24 hours", connectionState(src("c1"), runs.filter((r) => r.job !== "forms_poll"), NOW), "attention", "ok");
expect("connection attention when silent for a day", connectionState(src("c3", { lastEventAt: at(25 * 3600) }), runs, NOW), "attention", "ok");
expect("connection ok", connectionState(src("c3"), runs, NOW), "ok", "attention");
expect("connection ok without events yet", connectionState(src("c5", { events24h: 0, lastEventAt: null }), runs, NOW), "ok", "attention");

// Probe
expect("probe fast, slow, down", [probeState(12), probeState(201), probeState(null)], ["fast", "slow", "down"], ["slow", "fast", "fast"]);

// Grouping
expect("runs grouped per job in the page's order", runsByJob(runs).map((g) => `${g.job}:${g.runs.length}`),
  ["link_calls:2", "forms_poll:1", "email_poll:1", "reconcile:2", "close_forgotten_workdays:1", "backfill:1"], ["backfill:1"]);
expect("the latest run first within a job", runsByJob(runs)[0].runs[0].lastStartedAt, at(50), at(110));
expect("an unknown job sorts after the known ones", runsByJob([run("zz_new", "c1", "succeeded", 1, 0), runs[0]]).map((g) => g.job), ["link_calls", "zz_new"], ["zz_new", "link_calls"]);
expect("the job order names every scheduled job", ["link_calls", "forms_poll", "email_poll", "reconcile", "close_forgotten_workdays"].every((j) => JOB_ORDER.includes(j)), true, false);

// Documents: names
expect("every allowlisted name is a document name", DOCUMENT_ALLOWLIST.every((n) => isDocumentName(n)), true, false);
const bad = ["../REPORT.md", "docs/REPORT.md", "REPORT.md/..", "REPORT.md\u0000", "..", ".", "", "report.md", "REPORT.MD", "REPORT.md ", " REPORT.md",
  "%2e%2e/REPORT.md", "C:\\REPORT.md", "REPORT.md;rm", "a".repeat(65), "manifest.json", "package.json", "../../etc/passwd", "REPORT.md\n", null, undefined, 42, {}];
expect("no separator, dot-dot, case variant or stranger is a document name", bad.filter((n) => isDocumentName(n)), [], ["REPORT.MD"]);

// Documents: manifest
const good = { version: "abc1234", writtenAt: "2026-10-17T12:00:00.000Z", documents: [{ name: "REPORT.md", bytes: 1200, sha256: "a".repeat(64) }, { name: "FINDINGS.csv", bytes: 300, sha256: "b".repeat(64) }] };
expect("a well-formed manifest parses", parseManifest(good)?.documents.map((d) => d.name), ["REPORT.md", "FINDINGS.csv"], ["REPORT.md"]);
expect("a manifest naming a file outside the list is refused", parseManifest({ ...good, documents: [{ name: "secrets.env", bytes: 1, sha256: "a".repeat(64) }] }), null, good);
expect("a manifest with a bad hash is refused", parseManifest({ ...good, documents: [{ name: "REPORT.md", bytes: 1, sha256: "xyz" }] }), null, good);
expect("a manifest missing a field is refused", [parseManifest({ documents: [] }), parseManifest(null), parseManifest("x"), parseManifest({ ...good, documents: "no" })], [null, null, null, null], [good, good, good, good]);
expect("an entry by name, none for a name outside this build", [documentEntry(parseManifest(good), "FINDINGS.csv")?.bytes, documentEntry(parseManifest(good), "READINESS.md"), documentEntry(parseManifest(good), "../REPORT.md"), documentEntry(null, "REPORT.md")],
  [300, null, null, null], [1200, null, null, null]);
expect("content types: csv and markdown as downloads", [documentContentType("FINDINGS.csv"), documentContentType("REPORT.md")], ["text/csv; charset=utf-8", "text/markdown; charset=utf-8"], ["text/plain", "text/html"]);

const passed = results.filter(Boolean).length;
const verdict = PROVOKE ? (passed === 0 ? `ALL ${results.length} PROVOKED CHECKS FAILED` : `PROVOKE FAILED: ${passed} passed`) : (passed === results.length ? `ALL ${results.length} PASS` : `${results.length - passed} FAILED`);
console.log(verdict);
process.exit(PROVOKE ? (passed === 0 ? 0 : 1) : (passed === results.length ? 0 : 1));
