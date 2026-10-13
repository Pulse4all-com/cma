/**
 * The Aircall adapter as the server and the jobs see it. Route: POST /aircall/<connection key>.
 *
 *   authenticate, mapRequest, readBack   the webhook path (brief B9): the body's token, one event per
 *                                        request, the call read back from Aircall's API
 *   rates                                none: the adapter paces itself per connection (read.mjs)
 *   refreshCatalogs                      the sweep: lines and tags at most hourly per connection
 *   reconcileObjects, reconcile          the reconcile job: calls of the look-back, the webhook check
 *   backfillObjects, backfill            the backfill job: --object telephony_call
 */
import { getSecret } from "../../core/secrets.mjs";
import { verifyToken } from "./verify.mjs";
import { mapEvents } from "./map.mjs";
import { readBack, refreshCatalogs, replayAllowed } from "./read.mjs";
import { reconcile, backfill, RECONCILE_OBJECTS, BACKFILL_OBJECTS } from "./reconcile.mjs";

export const aircall = {
  name: "aircall",

  /** The body's token against the connection's signing secret; SecretUnavailable propagates (the server answers 500). */
  async authenticate({ body, connection }) {
    const secret = await getSecret(connection.signingSecretName);
    return verifyToken({ body, secret });
  },

  /** The authenticated body → one canonical event; throws SyntaxError on a body that is not one JSON object. */
  mapRequest(body) {
    return mapEvents(body, { inlineAllowed: replayAllowed() });
  },

  readBack,

  holdsRecords: false,
  rates: {},
  refreshCatalogs,
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
};
