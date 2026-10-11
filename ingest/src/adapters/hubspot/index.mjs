/**
 * The HubSpot adapter as the server and the jobs see it. Route: POST /hubspot/<connection key>.
 *
 *   authenticate, mapRequest, readBack   the webhook path (brief B7)
 *   holdsRecords                         the sweeper reads records without a contact again
 *   rates                                the jobs' pacing (read.mjs RATES)
 *   pollForms                            the poll-forms job (forms.mjs)
 *   reconcileObjects, reconcile          the reconcile job (reconcile.mjs)
 *   backfillObjects, backfill            the backfill job (backfill.mjs)
 */
import { getSecret } from "../../core/secrets.mjs";
import { verifyV3 } from "./verify.mjs";
import { mapEvents } from "./map.mjs";
import { readBack, RATES } from "./read.mjs";
import { pollForms } from "./forms.mjs";
import { reconcile, RECONCILE_OBJECTS } from "./reconcile.mjs";
import { backfill, BACKFILL_OBJECTS } from "./backfill.mjs";

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
  pollForms,
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
};
