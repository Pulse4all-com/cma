/**
 * Verifier: HubSpot payloads → canonical events and objects (src/adapters/hubspot/map.mjs), pure.
 * Fixtures under verify/fixtures/hubspot/ hold invented ids only. Since addition 0008u also a contact's
 * creation time (the object's own, and created_at slots 2 to 9 with the earliest kept by the database) and a
 * deal stage's outcome from its probability.
 *
 *   node verify/mapping.mjs             every check must PASS
 *   node verify/mapping.mjs --provoke   every check must FAIL
 */
import { readFileSync } from "node:fs";
import {
  mapEvents, propertiesFor, recordFromObject, contactFromObject, primaryContact, associationDiff, keptAssociation,
  taskFromObject, firstAssociated, TASK_PROPERTIES, stageOutcome,
} from "../src/adapters/hubspot/map.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/mapping.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/hubspot/${name}`, import.meta.url), "utf8"));
const PORTAL = "9000001";
const generic = mapEvents(fixture("generic-batch.json"), PORTAL);
const byKey = new Map(generic.map((e) => [e.key, e]));
const ev = (id) => byKey.get(`hs:${id}`);

// Events
expect("one canonical event per webhook event", generic.length, 10, 9);
expect("event key is hs:<eventId>", generic[0].key, "hs:3000000101", "3000000101");
expect("deal creation → created deal", [ev(3000000101).kind, ev(3000000101).objectType, ev(3000000101).objectId], ["created", "deal", "4100000001"], ["created", "deal", "0"]);
expect("occurredAt in ISO 8601", ev(3000000101).occurredAt, "2026-10-10T09:00:00.000Z", 1760086800000);
expect("attempt is attemptNumber + 1", ev(3000000102).attempt, 2, 1);
expect("property change → changed with the property name", [ev(3000000102).kind, ev(3000000102).propertyName], ["changed", "dealstage"], ["changed", null]);
expect("call creation → created crm_call", [ev(3000000103).kind, ev(3000000103).objectType], ["created", "crm_call"], ["created", "call"]);
expect("contact→call association: the call is read back", [ev(3000000104).kind, ev(3000000104).objectType, ev(3000000104).objectId, ev(3000000104).ignore ?? null],
  ["associated", "crm_call", "4200000001", null], ["associated", "contact", "4300000001", null]);
expect("deal→company association is not kept", ev(3000000105).ignore, "association_not_kept", undefined);
expect("merge → merged on the surviving id, merged ids kept", [ev(3000000107).kind, ev(3000000107).objectId, ev(3000000107).raw.mergedObjectIds],
  ["merged", "4300000001", ["4300000002"]], ["merged", "4300000002", []]);
expect("deletion → deleted ticket", [ev(3000000108).kind, ev(3000000108).objectType], ["deleted", "ticket"], ["changed", "ticket"]);
expect("restore → restored deal", ev(3000000109).kind, "restored", "created");
expect("another portal → ignored portal_mismatch", ev(3000000110).ignore, "portal_mismatch", undefined);
expect("events of this portal are not ignored", generic.filter((e) => !e.ignore).length, 8, 10);
const allRaw = JSON.stringify(generic.map((e) => e.raw));
expect("no property value is kept (ids only)", allRaw.includes("closedwon-fixture") || allRaw.includes('"NL"'), false, true);
expect("no acting user is kept", allRaw.includes("userId:7000001"), false, true);
expect("raw keeps the event id and subscription", [ev(3000000101).raw.eventId, ev(3000000101).raw.subscriptionType], ["3000000101", "object.creation"], [null, null]);

const hub = mapEvents(fixture("hub-events.json"), PORTAL)[0];
expect("contact.privacyDeletion → deleted contact, privacy flag", [hub.kind, hub.objectType, hub.objectId, hub.raw.privacy], ["deleted", "contact", "4300000001", true], ["deleted", "contact", "4300000001", undefined]);

const legacy = mapEvents(fixture("legacy-batch.json"), PORTAL);
expect("deal.creation (object-named) → created deal", [legacy[0].kind, legacy[0].objectType, legacy[0].attempt], ["created", "deal", 3], ["created", "other", 1]);
expect("DEAL_TO_CONTACT removal → associated deal, removal noted", [legacy[1].objectType, legacy[1].objectId, legacy[1].raw.associationRemoved, legacy[1].raw.toId],
  ["deal", "4100000004", true, "4300000003"], ["contact", "4300000003", false, null]);
expect("an object (not an array) body is one event", mapEvents(fixture("hub-events.json")[0], PORTAL).length, 1, 0);
expect("an event without an id or object is kept as malformed", mapEvents([{ portalId: 9000001, subscriptionType: "object.creation", objectTypeId: "0-3" }], PORTAL)[0].ignore, "malformed", undefined);
expect("a company event is not kept", mapEvents([{ eventId: 1, portalId: 9000001, subscriptionType: "object.creation", objectTypeId: "0-2", objectId: 5 }], PORTAL)[0].ignore, "object_not_kept", undefined);
expect("kept association direction: deal → contact", keptAssociation("contact", "1", "deal", "2"), { fromType: "deal", fromId: "2", toType: "contact", toId: "1" }, null);

// Objects
const config = {
  fields: [
    { entity: "contact", field: "country", property: "contact_country" }, { entity: "contact", field: "language", property: "contact_language" },
    { entity: "contact", field: "ref", refSystem: "shopify", slot: 1, property: "contact_shopify_id_1" },
    { entity: "contact", field: "ref", refSystem: "shopify", slot: 2, property: "contact_shopify_id_2" },
    { entity: "deal", field: "amount", property: "amount" }, { entity: "deal", field: "currency", property: "deal_currency_code" },
  ],
  settings: {},
};
expect("deal properties: structural plus configured only", propertiesFor("deal", config),
  ["amount", "closedate", "createdate", "deal_currency_code", "dealstage", "hs_lastmodifieddate", "hubspot_owner_id", "pipeline"], ["dealname"]);
expect("contact properties: configured only", propertiesFor("contact", config), ["contact_country", "contact_language", "contact_shopify_id_1", "contact_shopify_id_2"], ["email"]);
const deal = { id: "4100000001", createdAt: "2026-10-10T09:00:00.000Z", updatedAt: "2026-10-10T09:01:00.000Z",
  properties: { pipeline: "p-sales", dealstage: "s-new", hubspot_owner_id: "7100000001", createdate: "2026-10-10T09:00:00.000Z", amount: "1200.50", deal_currency_code: "eur", dealname: "not requested" } };
const r = recordFromObject("deal", deal, config, { country: "uk", language: "en" });
expect("deal → record ids, pipeline, stage, owner", [r.sourceId, r.pipelineId, r.stageId, r.ownerRef], ["4100000001", "p-sales", "s-new", "7100000001"], ["4100000001", null, null, null]);
expect("record amount and currency from the mapping", [r.amount, r.currency], ["1200.50", "eur"], [null, null]);
expect("no market property mapped: the contact's country", [r.market, r.language], ["uk", "en"], [null, null]);
expect("record raw holds requested properties only", Object.keys(r.raw).includes("dealname"), false, true);
expect("record times", [r.createdAt, r.updatedAt], ["2026-10-10T09:00:00.000Z", "2026-10-10T09:01:00.000Z"], [null, null]);
const mapped = recordFromObject("deal", deal, { fields: [...config.fields, { entity: "deal", field: "market", property: "deal_market" }] }, { country: "GB" });
expect("a mapped market property wins over the contact", mapped.market ?? null, null, "GB");
const c = contactFromObject({ id: "4300000001", updatedAt: "2026-10-10T09:02:00.000Z", properties: { contact_country: "NL", contact_language: "nl", contact_shopify_id_2: "6000000002" } }, config);
expect("contact → country, language and two ref slots", [c.country, c.language, c.refs], ["NL", "nl", { shopify: [null, "6000000002"] }], ["NL", "nl", { shopify: ["6000000002"] }]);
expect("primary contact: the labelled one", primaryContact([{ toObjectId: 9 }, { toObjectId: 12, associationTypes: [{ label: "Primary" }] }]), "12", "9");
expect("primary contact: the held one when still associated", primaryContact([{ toObjectId: 9 }, { toObjectId: 12 }], "12"), "12", "9");
expect("primary contact: else the lowest id", primaryContact([{ toObjectId: 12 }, { toObjectId: 9 }]), "9", "12");
const at = "2026-10-10T10:00:00.000Z";
expect("association diff: new added, gone removed", associationDiff("deal", "1", [{ toType: "contact", toId: "2" }], [{ fromId: "1", toType: "contact", toId: "3" }], ["contact"], at),
  [{ fromType: "deal", fromId: "1", toType: "contact", toId: "2", removed: false, changedAt: at }, { fromType: "deal", fromId: "1", toType: "contact", toId: "3", removed: true, changedAt: at }], []);

// The contact's creation time and a deal stage's outcome (addition 0008u)
expect("contact → its own createdAt as slot 1, without an extra property", [c.createdAt, c.createdAts, propertiesFor("contact", config).includes("createdate")],
  [undefined, undefined, false], ["2026-01-01T00:00:00.000Z", undefined, true]);
const created = contactFromObject({ id: "4300000002", createdAt: "2026-10-01T08:00:00.000Z", updatedAt: "2026-10-10T09:02:00.000Z",
  properties: { old_crm_created: "2019-03-04", other_created: "" } },
  { fields: [{ entity: "contact", field: "created_at", slot: 2, property: "old_crm_created" }, { entity: "contact", field: "created_at", slot: 3, property: "other_created" }] });
expect("contact → createdAts per slot (slot 2 a date property), the database keeps the earliest", [created.createdAts, created.createdAt],
  [["2026-10-01T08:00:00.000Z", "2019-03-04T00:00:00.000Z", null], undefined], [undefined, "2026-10-01T08:00:00.000Z"]);
expect("contact → createdAt alone when no slot above 1 is mapped",
  contactFromObject({ id: "4300000003", createdAt: "2026-10-01T08:00:00.000Z", properties: {} }, { fields: [] }).createdAt, "2026-10-01T08:00:00.000Z", undefined);
expect("contact → a created_at property is requested only when mapped",
  propertiesFor("contact", { fields: [{ entity: "contact", field: "created_at", slot: 2, property: "old_crm_created" }] }), ["old_crm_created"], []);
expect("stage outcome: probability 1.0 won, a closed 0.0 lost, an open 0.0 and 0.5 none, a ticket stage none",
  [stageOutcome("deal", { metadata: { probability: "1.0", isClosed: "true" } }), stageOutcome("deal", { metadata: { probability: "0.0", isClosed: "true" } }),
    stageOutcome("deal", { metadata: { probability: "0.0", isClosed: "false" } }), stageOutcome("deal", { metadata: { probability: "0.5", isClosed: "false" } }),
    stageOutcome("deal", { metadata: { isClosed: "true" } }), stageOutcome("ticket", { metadata: { ticketState: "CLOSED", probability: "1.0" } })],
  ["won", "lost", null, null, null, null], ["won", "won", "lost", null, "lost", "won"]);

// Tasks (addition 0008n): events of object type 0-27, the association from a contact read back on the task,
// the eight structural properties and never body or subject, the first associated object
const taskEvents = mapEvents([
  { eventId: 3000000201, portalId: 9000001, subscriptionType: "object.creation", objectTypeId: "0-27", objectId: 4400000001, occurredAt: 1791622800000 },
  { eventId: 3000000202, portalId: 9000001, subscriptionType: "object.propertyChange", objectTypeId: "0-27", objectId: 4400000001, propertyName: "hs_task_status", propertyValue: "COMPLETED", occurredAt: 1791622860000 },
  { eventId: 3000000203, portalId: 9000001, subscriptionType: "object.associationChange", fromObjectTypeId: "0-1", toObjectTypeId: "0-27", fromObjectId: 4300000001, toObjectId: 4400000001, occurredAt: 1791622900000 },
  { eventId: 3000000204, portalId: 9000001, subscriptionType: "object.deletion", objectTypeId: "0-27", objectId: 4400000002, occurredAt: 1791622960000 },
], PORTAL);
expect("task creation → created task", [taskEvents[0].kind, taskEvents[0].objectType, taskEvents[0].objectId, taskEvents[0].ignore ?? null],
  ["created", "task", "4400000001", null], ["created", "other", "4400000001", "object_not_kept"]);
expect("a task's status change keeps the property name, never the value", [taskEvents[1].propertyName, JSON.stringify(taskEvents[1].raw).includes("COMPLETED")],
  ["hs_task_status", false], ["hs_task_status", true]);
expect("contact→task association: the task is read back", [taskEvents[2].objectType, taskEvents[2].objectId, taskEvents[2].raw.toType, taskEvents[2].ignore ?? null],
  ["task", "4400000001", "contact", null], ["contact", "4300000001", "task", null]);
expect("task deletion → deleted task", [taskEvents[3].kind, taskEvents[3].objectType], ["deleted", "task"], ["changed", "task"]);
expect("task properties: the eight structural ones, never body or subject",
  [propertiesFor("task", config), propertiesFor("task", config).some((p) => /body|subject|note/.test(p))],
  [[...TASK_PROPERTIES].sort(), false], [[...TASK_PROPERTIES, "hs_task_body"].sort(), false]);
const taskObj = { id: "4400000001", createdAt: "2026-10-10T08:00:00.000Z", updatedAt: "2026-10-10T09:05:00.000Z",
  properties: { hs_timestamp: "2026-10-12T09:00:00.000Z", hs_task_status: "NOT_STARTED", hs_task_type: "CALL", hs_task_priority: "HIGH", hubspot_owner_id: "7100000001",
    hs_task_body: "never stored", hs_task_subject: "never stored", hs_createdate: "2026-10-10T08:00:00.000Z", hs_lastmodifieddate: "2026-10-10T09:05:00.000Z" } };
const task = taskFromObject(taskObj, { contactId: "4300000001", dealId: "4100000001", ticketId: null });
expect("task → ids, refs, due and the associations", [task.sourceId, task.ownerRef, task.statusRef, task.typeRef, task.priorityRef, task.dueAt, task.completedAt, task.contactId, task.dealId, task.ticketId],
  ["4400000001", "7100000001", "NOT_STARTED", "CALL", "HIGH", "2026-10-12T09:00:00.000Z", null, "4300000001", "4100000001", null],
  ["4400000001", "7100000001", "NOT_STARTED", "CALL", "HIGH", "2026-10-12T09:00:00.000Z", null, null, null, null]);
expect("task times from the structural properties", [task.createdAt, task.updatedAt], ["2026-10-10T08:00:00.000Z", "2026-10-10T09:05:00.000Z"], [null, null]);
expect("task raw holds the structural properties only: no body, no subject", Object.keys(task.raw).sort(),
  ["hs_createdate", "hs_lastmodifieddate", "hs_task_priority", "hs_task_status", "hs_task_type", "hs_timestamp", "hubspot_owner_id"],
  ["hs_createdate", "hs_lastmodifieddate", "hs_task_body", "hs_task_priority", "hs_task_status", "hs_task_type", "hs_timestamp", "hubspot_owner_id"]);
expect("no task text anywhere in the item", JSON.stringify(task).includes("never stored"), false, true);
expect("the first associated object: the lowest id, none without one", [firstAssociated([{ toObjectId: 12 }, { toObjectId: 9 }]), firstAssociated([])], ["9", null], ["12", null]);
expect("kept association direction: task → deal", keptAssociation("deal", "1", "task", "2"), { fromType: "task", fromId: "2", toType: "deal", toId: "1" }, null);

verdict();
