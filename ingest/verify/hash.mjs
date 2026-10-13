/**
 * Verifier: the keyed hash of phone numbers (src/core/hash.mjs), pure. Fixture numbers only
 * (+44 20 0000 000x and +31 20 000 000x style, which no one answers).
 *
 *   node verify/hash.mjs             every check must PASS
 *   node verify/hash.mjs --provoke   every check must FAIL
 */
import { createHmac } from "node:crypto";
import { toE164, hashNumber } from "../src/core/hash.mjs";
import { callFromObject } from "../src/adapters/hubspot/map.mjs";
import { orderFromNode, customerFromNode } from "../src/adapters/shopify/map.mjs";
import { expect, verdict, PROVOKE } from "./lib.mjs";

console.log(`verify/hash.mjs${PROVOKE ? "  (--provoke: every check must FAIL)" : ""}\n`);

const PEPPER = "fixture-pepper-0000000000000000";
const H = (n, r) => hashNumber(PEPPER, n, r);
const reference = createHmac("sha256", PEPPER).update("+442000000001").digest("hex");

expect("international format → E.164", toE164("+44 20 0000 0001"), "+442000000001", "+44 20 0000 0001");
expect("national format with region GB → E.164", toE164("020 0000 0001", "GB"), "+442000000001", null);
expect("00 prefix with region GB → E.164", toE164("0044 20 0000 0001", "GB"), "+442000000001", null);
expect("national format with region NL → E.164", toE164("(020) 000-0001", "NL"), "+31200000001", "+442000000001");
expect("the hash is HMAC-SHA256(pepper, E.164) in hex", H("+44 20 0000 0001"), reference, "x");
expect("national and international formats hash the same", H("020 0000 0001", "GB") === H("+44 20 0000 0001"), true, false);
expect("spaces, dashes and brackets do not change the hash", H("+44 (0)20-0000-0001") === H("+442000000001"), true, false);
expect("another region reads a national number differently", H("020 0000 0001", "NL") === H("020 0000 0001", "GB"), false, true);
expect("a different pepper gives a different hash", hashNumber("another-pepper", "+442000000001") === H("+442000000001"), false, true);
expect("another number gives another hash", H("+442000000002") === H("+442000000001"), false, true);
expect("a national number without a region gives no hash", H("020 0000 0001"), null, reference);
expect("too short to be a number gives no hash", H("12", "GB"), null, "x");
expect("text gives no hash", H("anonymous", "GB"), null, "x");
expect("no pepper gives no hash", hashNumber("", "+442000000001"), null, reference);
expect("a lower-case region is not used", toE164("020 0000 0001", "gb"), null, "+442000000001");
expect("the hash is 64 lower-case hex characters", /^[0-9a-f]{64}$/.test(H("+31 20 000 0001")), true, false);

// A call read back from the CRM: the hash is there, no number is
const call = callFromObject({
  id: "7001", createdAt: "2026-10-10T09:00:00.000Z", updatedAt: "2026-10-10T09:05:00.000Z",
  properties: { hs_call_direction: "OUTBOUND", hs_call_to_number: "020 0000 0001", hs_call_from_number: "+31 20 000 0009", hs_timestamp: "2026-10-10T09:00:00.000Z", hs_call_duration: "61000" },
}, { pepper: PEPPER, region: "GB" });
const text = JSON.stringify(call);
expect("an outbound call hashes the number it called", call.counterpartHash, reference, null);
expect("no digits of either number remain in the call", /0000\s?0001|000\s?0009|200000000|31200/.test(text), false, true);
const inbound = callFromObject({ id: "7002", properties: { hs_call_direction: "INBOUND", hs_call_from_number: "+44 20 0000 0001", hs_call_to_number: "+31 20 000 0009" } }, { pepper: PEPPER });
expect("an inbound call hashes the number that called", inbound.counterpartHash, reference, null);
expect("a call of unknown direction gets no hash", callFromObject({ id: "7003", properties: { hs_call_to_number: "+442000000001" } }, { pepper: PEPPER }).counterpartHash, null, reference);

// Commerce (addition 0008g): the same pepper and the store's market as the default region, so an
// order's phone meets an earlier call's hash
const customer = { id: "gid://shopify/Customer/7100000001", defaultPhoneNumber: { phoneNumber: "+44 20 0000 0001" } };
const order = (o) => orderFromNode({ id: "gid://shopify/Order/7300000001", createdAt: "2026-10-12T10:00:00Z", customer, ...o }, { pepper: PEPPER, region: "GB" });
expect("an order's own phone (national, the store's market GB) hashes like the call", order({ phone: "020 0000 0001" }).phoneHash, reference, null);
expect("an order without a phone takes its customer's", order({ phone: null }).phoneHash, reference, null);
expect("the order's phone comes before its customer's", order({ phone: "+44 20 0000 0002" }).phoneHash, H("+442000000002"), reference);
expect("a customer's phone hashes like the call", customerFromNode(customer, { pepper: PEPPER, region: "GB" }).phoneHash, reference, null);
const withheld = orderFromNode({ id: "gid://shopify/Order/7300000002", createdAt: "2026-10-12T10:00:00Z", phone: null, customer: { id: "gid://shopify/Customer/7100000002", defaultPhoneNumber: null } }, { pepper: PEPPER, region: "GB" });
expect("Phone withheld by the store → no hash, nothing fails", withheld.phoneHash, null, reference);
const kept = JSON.stringify([order({ phone: "020 0000 0001" }), customerFromNode(customer, { pepper: PEPPER, region: "GB" })]);
expect("no form of the number remains in the order or the customer", ["+442000000001", "442000000001", "02000000001", "2000000001", "020 0000 0001", "20 0000 0001"].filter((f) => kept.includes(f)), [], ["+442000000001"]);

verdict();
