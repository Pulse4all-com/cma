/**
 * Verifier: the outbox worker's mode logic (src/adapters/hubspot/write.mjs, DESIGN §4.3a), pure: no
 * network, no database. The write-back fields are VENDOR_SETUP §1.1's as the runbook sets them; the
 * contacts' current values are invented.
 *
 *   node verify/outbox.mjs             every check must PASS
 *   node verify/outbox.mjs --provoke   every check must FAIL
 */
import { planWrite, assertConfigured, enabledFields, writeContacts } from "../src/adapters/hubspot/write.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/outbox.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const config = { writeback: [
  { field: "commerce_ref", slot: 1, property: "id_1", mode: "slot", enabled: true },
  { field: "commerce_ref", slot: 2, property: "id_2", mode: "slot", enabled: true },
  { field: "commerce_store", slot: 1, property: "store", mode: "always", enabled: true },
  { field: "commerce_orders", slot: 1, property: "orders", mode: "always", enabled: true },
  { field: "commerce_spent", slot: 1, property: "spent", mode: "always", enabled: true },
  { field: "country", slot: 1, property: "country", mode: "if_empty", enabled: true },
  { field: "currency", slot: 1, property: "currency", mode: "if_empty", enabled: false },
  { field: "language", slot: 1, property: "language", mode: "if_empty", enabled: true },
] };
const fields = enabledFields(config);
const payload = { commerce_ref: "7100000001", commerce_store: "shop-gb", commerce_orders: 2, commerce_spent: 240, country: "GB", currency: "GBP", language: "en" };
const plan = (current, p = payload) => planWrite(p, fields, current);

expect("only enabled fields are planned with (currency disabled)", fields.map((f) => f.property), ["id_1", "id_2", "store", "orders", "spent", "country", "language"], ["id_1", "id_2", "store", "orders", "spent", "country", "currency", "language"]);
let p = plan({});
expect("an empty contact: slot 1, store, totals, country and language written", p.properties, { id_1: "7100000001", store: "shop-gb", orders: "2", spent: "240", country: "GB", language: "en" }, {});
expect("…the result: ref written in slot 1", [p.ref, p.slot], ["written", 1], ["written", 2]);
p = plan({ country: "NL", language: "nl" });
expect("if_empty keeps an agent's country and language", [p.properties.country, p.properties.language, p.skipped.country, p.skipped.language], [undefined, undefined, "not_empty", "not_empty"], ["GB", "en", undefined, undefined]);
expect("if_empty: the same value is unchanged, not written", plan({ country: "GB" }).skipped.country, "unchanged", "not_empty");
p = plan({ id_1: "7199999999" });
expect("slot 1 held by another id → slot 2", [p.properties.id_1, p.properties.id_2, p.slot], [undefined, "7100000001", 2], ["7100000001", undefined, 1]);
expect("…and then no store or totals (they describe the customer in slot 1)", [p.properties.store, p.properties.orders, p.properties.spent, p.skipped.store], [undefined, undefined, undefined, "not_slot_one"], ["shop-gb", "2", "240", undefined]);
p = plan({ id_1: "7199999999", id_2: "7199999998" });
expect("both slots held by other ids → nothing of the ref, slots_full", [p.properties.id_1, p.properties.id_2, p.ref, p.skipped.id_1, p.skipped.id_2], [undefined, undefined, "slots_full", "slot_taken", "slot_taken"], ["7100000001", undefined, "written", undefined, undefined]);
p = plan({ id_1: "7199999999", id_2: "7100000001" });
expect("the id already in slot 2 → present, nothing written for the ref, no totals", [p.ref, p.slot, Object.keys(p.properties).filter((k) => k.startsWith("id_"))], ["present", 2, []], ["written", 1, ["id_1"]]);
p = plan({ id_1: "7100000001", store: "shop-gb", orders: "2", spent: "240.00", country: "GB", language: "en" });
expect("everything current → nothing to write (240 equals 240.00)", [p.written, p.ref], [[], "present"], [["spent"], "written"]);
p = plan({ id_1: "7100000001", store: "shop-gb", orders: "1", spent: "120", country: "GB", language: "en" });
expect("always writes only the difference", p.properties, { orders: "2", spent: "240" }, { store: "shop-gb", orders: "2", spent: "240" });
p = plan({ id_1: "7100000001", store: "another-shop" });
expect("always overwrites a different store", p.properties.store, "shop-gb", undefined);
p = plan({}, { country: "GB" });
expect("no customer id → no store or totals, the codes by their mode", [p.ref, p.properties], [null, { country: "GB" }], ["written", {}]);
expect("a planned property is always one of the enabled fields", Object.keys(plan({}).properties).every((k) => fields.some((f) => f.property === k)), true, false);

// The code refuses a property the configuration does not name, whatever the plan says
const refused = (props) => { try { assertConfigured(props, fields); return "accepted"; } catch (err) { return err.code; } };
expect("assertConfigured: a configured property passes", refused({ id_1: "1", country: "GB" }), "accepted", "property_not_configured");
expect("assertConfigured: a property not in the fields is refused", refused({ id_1: "1", contact_netsuite_id: "x" }), "property_not_configured", "accepted");
expect("assertConfigured: a disabled field's property is refused", refused({ currency: "GBP" }), "property_not_configured", "accepted");
expect("assertConfigured: email is refused", refused({ email: "someone@example.com" }), "property_not_configured", "accepted");

// writeContacts without a configuration writes nothing (no secret read, no call)
const out = await writeContacts({ connection: { connectionId: "c", tokenSecretName: "none" }, config: { writeback: [] }, budget: null,
  actions: [{ action_id: "a1", action: "crm.contact.set_properties", target_type: "contact", target_id: "1", payload }] });
expect("no enabled write-back field → the action fails writeback_not_configured", out, [{ ids: ["a1"], outcome: "failed", result: null, error: "writeback_not_configured" }], []);
const other = await writeContacts({ connection: { connectionId: "c", tokenSecretName: "none" }, config, budget: null,
  actions: [{ action_id: "a2", action: "crm.deal.assign_owner", target_type: "deal", target_id: "1", payload: {} }] });
expect("an action this writer does not handle → action_not_supported", other.map((g) => g.error), ["action_not_supported"], []);

verdict();
