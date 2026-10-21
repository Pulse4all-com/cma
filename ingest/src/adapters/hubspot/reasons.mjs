/**
 * The reason properties (addition 0008zb, brief N21): a deal's lost reason and a ticket's reason come from the property
 * the connection maps as the field reason (Configuration, Sources), and only from an enumeration, whose values are the
 * options' internal values: a text property can hold anything a person types, personal data included, so it is never
 * read (0008p's choice answers only). The sweep (every minute) reads the definition of a mapped reason property that has
 * not been read yet, or not for an hour (REASON_CHECK_EVERY_MS), and hands it to cma.ingest_upsert_reasons: the type
 * (enumeration, string, …, or missing when HubSpot has no such property) on the field, and an enumeration's options
 * into the catalog, where a person's data-quality flag stays. Sources shows the state: a text property refused, an
 * enumeration with its options. Until the type is known the record read asks for no reason property (map.mjs fieldsOf).
 * One GET per due property; nothing is read while every field is fresh.
 */
import { contextOf } from "../../core/connection.mjs";
import { SourceError } from "../../core/http.mjs";
import { applyUnits } from "../../core/store.mjs";
import { info, warn } from "../../core/log.mjs";
import { hubspotClient, tokenOf } from "./read.mjs";
import { reasonFieldsOf, reasonCheckDue, reasonItemOf } from "./map.mjs";

/** The sweep's catalog step for HubSpot: the due reason properties read and written; true when any was. */
export async function refreshReasons({ connection, store, budget, now = Date.now() }) {
  const config = await store.config();
  const due = reasonFieldsOf(config).filter((f) => reasonCheckDue(f, now));
  if (!due.length) return false;
  const api = hubspotClient(await tokenOf(connection), budget);
  const items = [];
  for (const f of due) {
    let def;
    try {
      def = await api.property(f.recordType, f.property);
    } catch (err) {
      // A property HubSpot does not have is recorded as missing; any other failure is tried again on the next run
      if (err instanceof SourceError && err.status === 404) def = null;
      else {
        warn("reason property not read", { connection: connection.connectionId, recordType: f.recordType, code: err?.code ?? "error" });
        continue;
      }
    }
    items.push(reasonItemOf(f.recordType, f.property, def));
  }
  if (!items.length) return false;
  await applyUnits(contextOf(connection), connection.connectionId, [{ eventIds: [], status: "processed", error: null, writes: { reasons: items } }]);
  info("hubspot reason properties", {
    connection: connection.connectionId, checked: items.length,
    types: items.map((i) => `${i.recordType}:${i.type}`), options: items.reduce((n, i) => n + (i.options?.length ?? 0), 0),
  });
  return true;
}
