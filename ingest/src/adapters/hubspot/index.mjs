/**
 * The HubSpot adapter as the server and the jobs see it. Route: POST /hubspot/<connection key>.
 *
 *   authenticate, mapRequest, readBack   the webhook path (brief B7)
 *   holdsRecords                         the sweeper reads records without a contact again
 *   refreshCatalogs                      the sweep: the mapped reason properties' types and options, at most hourly
 *                                        each (reasons.mjs, addition 0008zb)
 *   rates                                the jobs' pacing (read.mjs RATES)
 *   pollForms                            the poll-forms job (forms.mjs)
 *   pollEmail, emailPollEnabled          the poll-email job (email-poll.mjs: engagements in email.mjs,
 *                                        inbox conversations in conversations.mjs; brief B17b)
 *   reconcileObjects, reconcile          the reconcile job (reconcile.mjs); reconcileObjectsOf: the email
 *                                        objects (crm_email, inbox_thread) only where email_poll is on
 *   backfillObjects, backfill            the backfill job (backfill.mjs); backfillFrom: the email objects'
 *                                        default start (cma.email_start_date_of)
 *   dailyFloor                           the floor below which a backfill or reconcile pauses: the
 *                                        connection's api_daily_floor_pct (usage.mjs, backlog CMA-069)
 *   crm                                  contact lookups for another adapter's match (match.mjs: the
 *                                        commerce customer's contact, kept in the CMA, 0008h); for the legacy
 *                                        call import (0008zg) also by any email and by phone, with the
 *                                        properties those rely on and a check that the portal holds them
 *   writeContacts                        the outbox job: claimed contact write-backs (write.mjs; generic,
 *                                        unused for commerce since 0008h)
 */
import { getSecret } from "../../core/secrets.mjs";
import { verifyV3 } from "./verify.mjs";
import { mapEvents } from "./map.mjs";
import { readBack, RATES } from "./read.mjs";
import { pollForms } from "./forms.mjs";
import { pollEmail, emailPollEnabled } from "./email-poll.mjs";
import { reconcile, RECONCILE_OBJECTS } from "./reconcile.mjs";
import { backfill, backfillFrom, BACKFILL_OBJECTS } from "./backfill.mjs";
import { refreshReasons } from "./reasons.mjs";
import {
  findContactsByEmail, findContactsByProperties, existingContacts, findContactsByAnyEmail, findContactsByPhone, missingContactProperties,
  LOOKUP_PROPERTIES,
} from "./match.mjs";
import { writeContacts } from "./write.mjs";
import { usageSettings } from "./usage.mjs";
import { warn } from "../../core/log.mjs";

export const hubspot = {
  name: "hubspot",

  /** v3 signature with the app's client secret; SecretUnavailable propagates (the server answers 500). */
  async authenticate({ method, uris, body, headers, connection }) {
    const secret = await getSecret(connection.signingSecretName);
    return verifyV3({ method, uris, body, headers, secret });
  },

  /** The authenticated body → canonical events; throws SyntaxError on a body that is not JSON. */
  mapRequest(body, connection) {
    return mapEvents(JSON.parse(body.toString("utf8")), connection.externalAccountId);
  },

  readBack,

  holdsRecords: true,
  rates: RATES,
  refreshCatalogs: refreshReasons,
  pollForms,
  pollEmail,
  emailPollEnabled,
  reconcileObjects: RECONCILE_OBJECTS,
  async reconcileObjectsOf(store) {
    const email = emailPollEnabled(await store.config());
    return RECONCILE_OBJECTS.filter((o) => email || (o !== "crm_email" && o !== "inbox_thread"));
  },
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
  backfillFrom,
  /** The connection's floor in percent of HubSpot's daily limit; one log line names a setting out of range */
  async dailyFloor({ store, connection, job }) {
    const usage = usageSettings(await store.config());
    if (usage.fallbacks.includes("api_daily_floor_pct")) {
      warn("settings out of range, defaults used", { connection: connection.connectionId, job, settings: ["api_daily_floor_pct"] });
    }
    return usage.floorPct;
  },
  crm: {
    findContactsByEmail, findContactsByProperties, existingContacts, findContactsByAnyEmail, findContactsByPhone, missingContactProperties,
    lookupProperties: LOOKUP_PROPERTIES,
  },
  writeContacts,
};
