/**
 * Verifier: Aircall → canonical shapes (src/adapters/aircall/map.mjs) and the adapter's pure rules
 * (replay, pace setting, the reset after a 429, day windows), pure: no network, no database. The
 * fixtures (verify/fixtures/aircall/) hold invented ids, +44 20 0000 0xxx numbers and example.com.
 *
 *   node verify/aircall-mapping.mjs             every check must PASS
 *   node verify/aircall-mapping.mjs --provoke   every check must FAIL
 */
import { readFileSync } from "node:fs";
import { createHmac } from "node:crypto";
import { mapEvent, mapEvents, callFromObject, tagsOf, rawOf, fingerprint, unixIso, numberItem, tagItem, EVENTS } from "../src/adapters/aircall/map.mjs";
import { replayOn, perMinuteOf, resetAt, paceOf } from "../src/adapters/aircall/read.mjs";
import { dayWindows } from "../src/adapters/aircall/reconcile.mjs";
import { aircall } from "../src/adapters/aircall/index.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/aircall-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const lifecycle = JSON.parse(readFileSync(new URL("./fixtures/aircall/call-lifecycle.json", import.meta.url), "utf8"));
const notHandled = JSON.parse(readFileSync(new URL("./fixtures/aircall/not-handled.json", import.meta.url), "utf8"));
const PEPPER = "fixture-pepper-aircall-0000000000";
const H = (e164) => createHmac("sha256", PEPPER).update(e164).digest("hex");
const T = 1791622800;

// ---- Events ----------------------------------------------------------------------------------------
const mapped = lifecycle.map((p) => mapEvent(p));
expect("the six events are the six of the subscription", Object.keys(EVENTS), ["call.created", "call.answered", "call.ended", "call.tagged", "call.untagged", "call.archived"], []);
expect("each of the six → its key ac:<event>:<call id>:<timestamp>", mapped.map((e) => e.key), [
  `ac:call.created:9100000001:${T + 1}`, `ac:call.answered:9100000001:${T + 9}`, `ac:call.ended:9100000001:${T + 101}`,
  `ac:call.tagged:9100000001:${T + 102}`, `ac:call.untagged:9100000001:${T + 103}`, `ac:call.archived:9100000001:${T + 104}`], []);
expect("…kinds: created, then changed for the other five", mapped.map((e) => e.kind), ["created", "changed", "changed", "changed", "changed", "changed"], ["created", "changed", "changed", "changed", "changed", "deleted"]);
expect("…object telephony_call with the call's id, the event as source type", mapped.map((e) => `${e.objectType}:${e.objectId}:${e.sourceType}`)[2], "telephony_call:9100000001:call.ended", "telephony_call:9100000001:call.created");
expect("…occurred at the event's timestamp (UNIX seconds)", mapped[0].occurredAt, new Date((T + 1) * 1000).toISOString(), new Date(T + 1).toISOString());
expect("…none ignored", mapped.filter((e) => e.ignore).length, 0, 6);
expect("…raw holds the event, resource and timestamp only", mapped[3].raw, { event: "call.tagged", resource: "call", timestamp: T + 102 }, { event: "call.tagged" });
const recorded = JSON.stringify(mapped);
expect("…no token, number, name, email, comment or link in the events", /fixture-aircall-webhook-token|0000 0001|Invented|example\.com|must not be stored|https:/.test(recorded), false, true);
expect("…and no object in memory without the replay allowance", mapped.some((e) => e.inline), false, true);
const twice = mapEvent(lifecycle[1]);
expect("the same delivery again gives the same key (Aircall's retries are absorbed)", twice.key, mapped[1].key, `${mapped[1].key}x`);
const nh = notHandled.map((p) => mapEvent(p));
expect("another call event (call.hungup) → recorded as ignored, event_not_handled", [nh[0].objectType, nh[0].ignore], ["telephony_call", "event_not_handled"], ["telephony_call", undefined]);
expect("another resource (user, contact) → ignored, event_not_handled, under its own type", nh.slice(1).map((e) => `${e.objectType}:${e.ignore}`), ["user:event_not_handled", "contact:event_not_handled"], ["user:undefined", "contact:undefined"]);
expect("…and the contact's name, number and email are not in the event", /Invented|Customer|0000 0001|example\.com/.test(JSON.stringify(nh)), false, true);
expect("a call event without a call id → ignored, malformed", mapEvent({ resource: "call", event: "call.ended", timestamp: T, data: {} }).ignore, "malformed", undefined);
expect("a call event without a timestamp keeps a stable key", mapEvent({ resource: "call", event: "call.ended", data: { id: 5 } }).key, "ac:call.ended:5:none", "ac:call.ended:5:");
expect("a body that is not one object is refused (the server answers 400)", (() => { try { mapEvents(Buffer.from("[1,2]")); return "mapped"; } catch { return "refused"; } })(), "refused", "mapped");

// Replay: the event's own object is held in memory only with the allowance, and only for that request
const withInline = mapEvent(lifecycle[2], { inlineAllowed: true });
expect("with the replay allowance the event holds its own call in memory", [withInline.inline?.source, withInline.inline?.object?.id, withInline.inline?.at], ["replay", 9100000001, new Date((T + 101) * 1000).toISOString()], [undefined, undefined, undefined]);
const saved = process.env.INGEST_ALLOW_REPLAY;
delete process.env.INGEST_ALLOW_REPLAY;
const prodLike = aircall.mapRequest(Buffer.from(JSON.stringify(lifecycle[2])));
process.env.INGEST_ALLOW_REPLAY = "1";
const devLike = aircall.mapRequest(Buffer.from(JSON.stringify(lifecycle[2])));
expect("the adapter attaches it only when INGEST_ALLOW_REPLAY=1", [Boolean(prodLike[0].inline), Boolean(devLike[0].inline)], [false, true], [true, true]);
expect("replay is on only with INGEST_ALLOW_REPLAY=1 and the setting", [replayOn({ replay: true }), replayOn({ replay: "true" }), replayOn({}), replayOn({ replay: "yes" })], [true, true, false, false], [false, false, false, false]);
delete process.env.INGEST_ALLOW_REPLAY;
expect("without the variable the setting does nothing (a prod-configured service)", replayOn({ replay: true }), false, true);
if (saved !== undefined) process.env.INGEST_ALLOW_REPLAY = saved;

// ---- Calls -------------------------------------------------------------------------------------------
const ended = lifecycle[4].data;
const at = "2026-10-10T09:02:00.000Z";
const call = callFromObject(ended, { pepper: PEPPER, region: "GB", versionAt: at });
expect("a call → direction, status, times (UNIX → ISO), duration", [call.direction, call.status, call.startedAt, call.answeredAt, call.endedAt, call.durationSeconds],
  ["outbound", "done", "2026-10-10T09:00:00.000Z", "2026-10-10T09:00:08.000Z", "2026-10-10T09:01:11.000Z", 71], []);
expect("…the user and the line as ids only, archived, the version", [call.userRef, call.numberRef, call.isArchived, call.versionAt], ["9200000001", "9300000001", false, at], []);
expect("…the other party's number as HMAC(pepper, E.164)", call.counterpartHash, H("+442000000001"), null);
expect("…its whole current tag set", call.tags, [{ tagRef: "9400000001", name: "Interested" }], []);
expect("…raw holds the allowlisted keys only", Object.keys(call.raw).sort(), ["answered_at", "archived", "direction", "duration", "ended_at", "started_at", "status"], ["archived", "cost", "direction"]);
const text = JSON.stringify(callFromObject(lifecycle[2].data, { pepper: PEPPER, region: "GB", versionAt: at }));
expect("…no number, name, email, comment, recording or link anywhere in the item", /20 ?0000 ?0001|442000000001|0000 ?0900|Invented|Agent|example\.com|must not be stored|recording|asset|https?:|CAxx/.test(text), false, true);
expect("…the line's number neither", /2000000900/.test(text), false, true);
const national = callFromObject({ ...ended, raw_digits: "020 0000 0002" }, { pepper: PEPPER, region: "GB", versionAt: at });
expect("a national number takes the region given (the line's market)", national.counterpartHash, H("+442000000002"), null);
const otherRegion = callFromObject({ ...ended, raw_digits: "020 0000 0002" }, { pepper: PEPPER, region: "NL", versionAt: at }).counterpartHash;
expect("…another region reads it differently", [Boolean(otherRegion), otherRegion === H("+442000000002")], [true, false], [true, true]);
expect("an anonymous caller gets no hash", callFromObject({ ...ended, raw_digits: "anonymous" }, { pepper: PEPPER, region: "GB", versionAt: at }).counterpartHash, null, "x");
const missed = callFromObject({ ...lifecycle[0].data, direction: "inbound", status: "done", missed_call_reason: "agents_did_not_answer", ended_at: T + 30, duration: 30 }, { pepper: PEPPER, versionAt: at });
expect("an unanswered inbound call: missed reason, no answer time", [missed.direction, missed.missedReason, missed.answeredAt], ["inbound", "agents_did_not_answer", null], ["inbound", null, null]);
expect("a call without tags in the object leaves the tag set out (tags kept as they are)", "tags" in callFromObject({ ...ended, tags: undefined }, { pepper: PEPPER, versionAt: at }), false, true);
expect("an empty tag list is the empty set (closes every tag)", callFromObject({ ...ended, tags: [] }, { pepper: PEPPER, versionAt: at }).tags, [], null);
expect("tags: ids as refs, names, duplicates once, tagged_by left out", tagsOf({ tags: [{ id: 1, name: "A", tagged_by: { name: "x" } }, { id: 1, name: "A" }, { name: "no id" }] }), [{ tagRef: "1", name: "A" }], []);
expect("an object without a direction is not a call", callFromObject({ id: 1 }, { pepper: PEPPER, versionAt: at }), null, {});
expect("rawOf drops nested objects and long strings", rawOf({ status: "done", user: { id: 1 }, duration: 3, missed_call_reason: "x".repeat(61) }), { status: "done", duration: 3 }, { status: "done" });
expect("unixIso: 0 and empty are no time", [unixIso(0), unixIso(""), unixIso(null)], [null, null, null], ["1970-01-01T00:00:00.000Z", null, null]);

// The fingerprint: what is kept, never the number
expect("the fingerprint ignores the number", fingerprint(ended) === fingerprint({ ...ended, raw_digits: "+44 20 0000 0002" }), true, false);
expect("…and changes when a tag, the status or the archive changes", [fingerprint(ended) !== fingerprint({ ...ended, tags: [] }), fingerprint(ended) !== fingerprint({ ...ended, status: "answered" }), fingerprint(ended) !== fingerprint({ ...ended, archived: true })], [true, true, true], [false, false, false]);

// Catalogs
expect("a line → ref, name, digits (the company's own number)", numberItem(ended.number), { numberRef: "9300000001", name: "Test line GB", digits: "+44 20 0000 0900" }, null);
expect("a tag → ref and name (colour left out)", tagItem({ id: 9400000002, name: "Call back", color: "#FFAA00" }), { tagRef: "9400000002", name: "Call back" }, null);

// ---- Pacing, reset, windows -------------------------------------------------------------------------
expect("aircall_max_per_minute: default 60, numbers and digit strings 1 to 120", [perMinuteOf({}), perMinuteOf({ aircall_max_per_minute: 30 }), perMinuteOf({ aircall_max_per_minute: "20" }), perMinuteOf({ aircall_max_per_minute: 500 }), perMinuteOf({ aircall_max_per_minute: "fast" })],
  [60, 30, 20, 60, 60], [60, 60, 60, 500, 60]);
const pace = paceOf("verify-connection", 30);
expect("…a pace of 30 per minute lets one call through every 2 seconds", pace.interval, 2000, 1000);
expect("…the same connection keeps its pace", paceOf("verify-connection", 30) === pace, true, false);
const now = Date.parse("2026-10-13T10:00:00Z");
expect("after a 429: until X-AircallApi-Reset (UNIX seconds)", resetAt({ "x-aircallapi-reset": String(now / 1000 + 30) }, now) - now, 30_000, 0);
expect("…in milliseconds too", resetAt({ "x-aircallapi-reset": String(now + 20_000) }, now) - now, 20_000, 0);
expect("…60 seconds without the header, never more than 70", [resetAt({}, now) - now, resetAt({ "x-aircallapi-reset": String(now / 1000 + 600) }, now) - now], [60_000, 70_000], [0, 600_000]);
const day = 24 * 60 * 60_000;
expect("26 hours → two day windows, the second of 2 hours", dayWindows(now - 26 * 3600_000, now).map(([a, b]) => (b - a) / 3600_000), [24, 2], [26]);
expect("a backfill of 12 days → 12 windows", dayWindows(now - 12 * day, now).length, 12, 1);

verdict();
