/**
 * Verifier: the HubSpot adapter's stage times (addition 0008za) and reasons (addition 0008zb), pure: the stage time
 * property names built from stage ids (HubSpot's characters, a hyphenated id among them), the stages that read times,
 * the stage times of a read record, the webhook's stage read plan and its limits, the --again version of the backfill,
 * and the reason property read only as an enumeration. Invented ids only.
 *
 *   node verify/funnel-mapping.mjs             every check must PASS
 *   node verify/funnel-mapping.mjs --provoke   every check must FAIL
 */
import {
  stageTimeProperty, timedStagesOf, stagePropertiesFor, stageTimesFromObject, stageReadPlan, propertiesFor, recordFromObject,
  fieldsOf, reasonFieldsOf, reasonCheckDue, reasonItemOf, REASON_CHECK_EVERY_MS,
} from "../src/adapters/hubspot/map.mjs";
import { stageReadLimits } from "../src/adapters/hubspot/read.mjs";
import { againVersion } from "../src/adapters/hubspot/backfill.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/funnel-mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

// ---- Stage time property names ------------------------------------------------------------------
expect("a default deal stage: hs_v2_date_entered_closedlost", stageTimeProperty("entered", "closedlost"), "hs_v2_date_entered_closedlost", "hs_v2_date_entered_closedLost");
expect("a ticket stage of digits: hs_v2_date_exited_1", stageTimeProperty("exited", "1"), "hs_v2_date_exited_1", "hs_v2_date_exited_");
expect("a hyphenated stage id: the hyphen becomes an underscore", stageTimeProperty("entered", "quote-sent"), "hs_v2_date_entered_quote_sent", "hs_v2_date_entered_quote-sent");
expect("a stage id with a uuid's hyphens", stageTimeProperty("exited", "3f2a9c1e-77b0-4c1d-9e2a-0b5d6f7a8c9d"),
  "hs_v2_date_exited_3f2a9c1e_77b0_4c1d_9e2a_0b5d6f7a8c9d", "hs_v2_date_exited_3f2a9c1e-77b0-4c1d-9e2a-0b5d6f7a8c9d");
expect("upper case lowered; a dot and a space become underscores", stageTimeProperty("entered", "Quote.Sent 2"), "hs_v2_date_entered_quote_sent_2", "hs_v2_date_entered_Quote.Sent 2");
expect("an underscore and digits stay", stageTimeProperty("entered", "stage_12"), "hs_v2_date_entered_stage_12", "hs_v2_date_entered_stage12");
expect("an empty stage id gives no property", stageTimeProperty("entered", ""), null, "hs_v2_date_entered_");
expect("only entered and exited are stage times", (() => { try { stageTimeProperty("cumulative", "x"); return "built"; } catch { return "refused"; } })(), "refused", "built");

// ---- The stages that read times ------------------------------------------------------------------
const config = {
  fields: [
    { entity: "deal", field: "amount", property: "amount" },
    { entity: "deal", field: "reason", property: "lost_dropdown", sourceType: "enumeration", checkedAt: "2026-10-20T08:00:00.000Z" },
    { entity: "ticket", field: "reason", property: "cancel_text", sourceType: "string", checkedAt: "2026-10-20T08:00:00.000Z" },
  ],
  pipelines: [
    { recordType: "deal", pipelineId: "sales", stages: [
      { stageId: "appointmentscheduled", readTimes: true, status: "active" }, { stageId: "quote-sent", readTimes: true, status: "active" },
      { stageId: "closedwon", readTimes: false, status: "active" }, { stageId: "old", readTimes: true, status: "archived" }] },
    { recordType: "deal", pipelineId: "other", stages: [{ stageId: "Quote_Sent", readTimes: true, status: "active" }, { stageId: "x9", readTimes: true, status: "active" }] },
    { recordType: "ticket", pipelineId: "support", stages: [{ stageId: "1", readTimes: true, status: "active" }, { stageId: "4", readTimes: false, status: "active" }] },
  ],
  settings: {},
};
expect("timed stages: read on and active, of the record type, a duplicate name once",
  timedStagesOf("deal", config).map((s) => `${s.pipelineId}/${s.stageId}`), ["sales/appointmentscheduled", "sales/quote-sent", "other/x9"],
  ["sales/appointmentscheduled", "sales/quote-sent", "sales/closedwon", "other/Quote_Sent", "other/x9"]);
expect("a ticket's timed stages", timedStagesOf("ticket", config).map((s) => s.entered), ["hs_v2_date_entered_1"], ["hs_v2_date_entered_1", "hs_v2_date_entered_4"]);
expect("the stage properties: two per timed stage, sorted", stagePropertiesFor("deal", config), [
  "hs_v2_date_entered_appointmentscheduled", "hs_v2_date_entered_quote_sent", "hs_v2_date_entered_x9",
  "hs_v2_date_exited_appointmentscheduled", "hs_v2_date_exited_quote_sent", "hs_v2_date_exited_x9"], ["hs_v2_date_entered_appointmentscheduled"]);
expect("the record's own properties hold no stage time (none in raw)", propertiesFor("deal", config).some((p) => p.startsWith("hs_v2_date_")), false, true);
expect("no pipelines read: no stage properties", stagePropertiesFor("deal", { fields: [] }), [], ["hs_v2_date_entered_x"]);

// ---- The stage times of a read record ------------------------------------------------------------
const deal = { id: "4100000001", updatedAt: "2026-10-20T09:00:00.000Z", properties: {
  hs_v2_date_entered_appointmentscheduled: "2026-10-10T08:00:00.000Z", hs_v2_date_exited_appointmentscheduled: "1791709200000",
  hs_v2_date_entered_quote_sent: "2026-10-14T09:00:00Z", hs_v2_date_exited_quote_sent: "", hs_v2_date_entered_x9: null, hs_v2_date_exited_x9: null } };
const times = stageTimesFromObject("deal", deal, config);
expect("stage times: the record, its source time, the stages answered", [times.recordType, times.sourceId, times.updatedAt, times.stages.length],
  ["deal", "4100000001", "2026-10-20T09:00:00.000Z", 2], ["deal", "4100000001", "2026-10-20T09:00:00.000Z", 3]);
expect("a time in milliseconds as ISO 8601", times.stages[0], { pipelineId: "sales", stageId: "appointmentscheduled", enteredAt: "2026-10-10T08:00:00.000Z", exitedAt: "2026-10-11T09:00:00.000Z" },
  { pipelineId: "sales", stageId: "appointmentscheduled", enteredAt: "2026-10-10T08:00:00.000Z", exitedAt: "1791709200000" });
expect("an empty exit is left out (the database keeps the stored one), never sent as a clear", times.stages[1],
  { pipelineId: "sales", stageId: "quote-sent", enteredAt: "2026-10-14T09:00:00.000Z" }, { pipelineId: "sales", stageId: "quote-sent", enteredAt: "2026-10-14T09:00:00.000Z", exitedAt: null });
expect("a stage without either time is left out", times.stages.some((s) => s.stageId === "x9"), false, true);
expect("the source time from hs_lastmodifieddate when the object has none",
  stageTimesFromObject("deal", { id: "2", properties: { hs_lastmodifieddate: "2026-10-19T10:00:00Z" } }, config).updatedAt, "2026-10-19T10:00:00.000Z", null);

// ---- The webhook's stage read plan ---------------------------------------------------------------
expect("a job (no deadline) always reads the stage times", stageReadPlan(Number.POSITIVE_INFINITY, 900), { read: true, reason: null }, { read: false, reason: "properties" });
expect("a webhook with the budget left reads them", stageReadPlan(2800, 12), { read: true, reason: null }, { read: false, reason: "budget" });
expect("a webhook without enough budget defers them: budget", stageReadPlan(1200, 12), { read: false, reason: "budget" }, { read: true, reason: null });
expect("a webhook with too many stage properties defers them: properties", stageReadPlan(2800, 401), { read: false, reason: "properties" }, { read: true, reason: null });
expect("no timed stage: nothing to read or defer", stageReadPlan(100, 0), { read: false, reason: null }, { read: false, reason: "budget" });
const saved = { min: process.env.INGEST_STAGE_READ_MIN_MS, max: process.env.INGEST_STAGE_READ_MAX_PROPERTIES };
delete process.env.INGEST_STAGE_READ_MIN_MS;
delete process.env.INGEST_STAGE_READ_MAX_PROPERTIES;
const defaults = stageReadLimits();
process.env.INGEST_STAGE_READ_MIN_MS = "2500";
process.env.INGEST_STAGE_READ_MAX_PROPERTIES = "1";
const set = stageReadLimits();
process.env.INGEST_STAGE_READ_MIN_MS = "-1";
process.env.INGEST_STAGE_READ_MAX_PROPERTIES = "lots";
const wrong = stageReadLimits();
for (const [k, v] of [["INGEST_STAGE_READ_MIN_MS", saved.min], ["INGEST_STAGE_READ_MAX_PROPERTIES", saved.max]]) {
  if (v === undefined) delete process.env[k];
  else process.env[k] = v;
}
expect("the limits: defaults, set, out of range back to the defaults", [defaults, set.minMs, set.maxProperties, wrong],
  [{ minMs: 1500, maxProperties: 400 }, 2500, 400, { minMs: 1500, maxProperties: 400 }], [{ minMs: 3000, maxProperties: 400 }, 2500, 1, { minMs: -1, maxProperties: 400 }]);

// ---- The backfill's --again version --------------------------------------------------------------
const v1 = againVersion("2026-10-12T08:00:00.000Z", 1792483200000);
expect("--again: the modified time and the run, at most 40 characters", [v1, v1.length <= 40], ["2026-10-12T08:00:00.000Z~a1792483200000", true], ["2026-10-12T08:00:00.000Z", true]);
expect("--again: another run another version, the same run the same", [againVersion("2026-10-12T08:00:00.000Z", 1792483200001) !== v1, againVersion("2026-10-12T08:00:00.000Z", 1792483200000) === v1],
  [true, true], [false, true]);

// ---- Reasons: an enumeration only ----------------------------------------------------------------
expect("a reason property is read only as an enumeration", [propertiesFor("deal", config).includes("lost_dropdown"), propertiesFor("ticket", config).includes("cancel_text")],
  [true, false], [true, true]);
expect("an unread reason property is not read", fieldsOf({ fields: [{ entity: "deal", field: "reason", property: "lost_dropdown" }] }, "deal"), [],
  [{ entity: "deal", field: "reason", property: "lost_dropdown" }]);
const rec = recordFromObject("deal", { id: "7", updatedAt: "2026-10-20T09:00:00.000Z", properties: { pipeline: "sales", dealstage: "closedlost", lost_dropdown: "  Too Expensive ", cancel_text: "a text" } }, config);
expect("the record's reason: the option's value, trimmed", [rec.reason, Object.keys(rec.raw).includes("cancel_text")], ["Too Expensive", false], ["  Too Expensive ", true]);
expect("a ticket with a text reason property carries no reason",
  recordFromObject("ticket", { id: "8", properties: { hs_pipeline: "support", cancel_text: "a text a person typed" } }, config).reason, undefined, "a text a person typed");
expect("the reason fields to check: deals and tickets, every state",
  reasonFieldsOf({ fields: [...config.fields, { entity: "contact", field: "country", property: "c" }, { entity: "deal", field: "reason", property: "" }] }).map((f) => `${f.recordType}:${f.property}:${f.sourceType}`),
  ["deal:lost_dropdown:enumeration", "ticket:cancel_text:string"], ["deal:lost_dropdown:enumeration"]);
const now = Date.parse("2026-10-20T08:30:00.000Z");
expect("a check is due: never read, read an hour ago or more; not due within the hour",
  [reasonCheckDue({ sourceType: null, checkedAt: null }, now), reasonCheckDue({ sourceType: "enumeration", checkedAt: "2026-10-20T07:30:00.000Z" }, now),
    reasonCheckDue({ sourceType: "enumeration", checkedAt: "2026-10-20T08:00:00.000Z" }, now), REASON_CHECK_EVERY_MS],
  [true, true, false, 3600000], [false, true, true, 3600000]);
const enumDef = { name: "lost_dropdown", type: "enumeration", fieldType: "select", options: [
  { value: "Garbage", label: "Garbage", displayOrder: 0 }, { value: "Too Expensive", label: "Too Expensive", displayOrder: 1, hidden: true },
  { value: "", label: "empty" }, { value: "x".repeat(101), label: "too long" }, { label: "no value" }] };
expect("an enumeration: its options' values with label and order, hidden ones kept, malformed ones out", reasonItemOf("deal", "lost_dropdown", enumDef),
  { recordType: "deal", property: "lost_dropdown", type: "enumeration", options: [{ value: "Garbage", label: "Garbage", order: 0 }, { value: "Too Expensive", label: "Too Expensive", order: 1 }] },
  { recordType: "deal", property: "lost_dropdown", type: "enumeration", options: [] });
expect("a text property: its type only, no options (refused on Sources)", reasonItemOf("deal", "closed_lost_reason", { type: "string", options: [] }),
  { recordType: "deal", property: "closed_lost_reason", type: "string" }, { recordType: "deal", property: "closed_lost_reason", type: "enumeration", options: [] });
expect("no such property: missing", reasonItemOf("ticket", "nope", null), { recordType: "ticket", property: "nope", type: "missing" }, { recordType: "ticket", property: "nope", type: "enumeration" });
expect("a type that is no word: unknown", reasonItemOf("deal", "p", { type: "1x" }).type, "unknown", "1x");

verdict();
