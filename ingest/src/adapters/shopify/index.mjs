/**
 * The Shopify adapter as the server and the jobs see it (brief B10). Route: POST /shopify/<connection key>.
 *
 *   authenticate, mapRequest, readBack   the webhook path: the HMAC of the raw body, one event per
 *                                        delivery keyed by its webhook id, the shop pinned, the
 *                                        customer or order read back through GraphQL (read.mjs) and
 *                                        matched to its CRM contact (match.mjs)
 *   readbackBudgetMs                     the route's own inline budget (INGEST_SHOPIFY_READBACK_BUDGET_MS,
 *                                        default 1500): Shopify gives a delivery five seconds in all
 *                                        and one second to connect, so the route answers well inside
 *                                        them and leaves the rest to the sweep
 *   rates                                none: the shop's cost bucket paces the GraphQL calls
 *                                        (client.mjs) and the CRM's search pace the lookups
 *   reconcileObjects, reconcile          the reconcile job: customers and orders updated in the look-back
 *   checkSubscriptions                   the reconcile job's subscription check (job subscriptions_check)
 *   backfillObjects, backfill            the backfill job: --object commerce_customer | commerce_order
 */
import { getSecret } from "../../core/secrets.mjs";
import { verifyHmac } from "./verify.mjs";
import { mapEvents } from "./map.mjs";
import { readBack } from "./read.mjs";
import { reconcile, backfill, checkSubscriptions, RECONCILE_OBJECTS, BACKFILL_OBJECTS } from "./reconcile.mjs";

export const DEFAULT_READBACK_BUDGET_MS = 1500;

/** INGEST_SHOPIFY_READBACK_BUDGET_MS: 100 to 4000 milliseconds, else 1500. */
export function shopifyReadbackBudgetMs() {
  const v = Number(process.env.INGEST_SHOPIFY_READBACK_BUDGET_MS ?? DEFAULT_READBACK_BUDGET_MS);
  return Number.isFinite(v) && v >= 100 && v <= 4000 ? v : DEFAULT_READBACK_BUDGET_MS;
}

export const shopify = {
  name: "shopify",

  /** The HMAC of the raw body with the app's client secret (the signing secret); SecretUnavailable propagates (500). */
  async authenticate({ body, headers, connection }) {
    const secret = await getSecret(connection.signingSecretName);
    return verifyHmac({ body, headers, secret });
  },

  /** The authenticated body and its headers → one canonical event; throws SyntaxError on a body that is not one JSON object. */
  mapRequest(body, connection, headers) {
    return mapEvents(body, headers, connection.externalAccountId);
  },

  readBack,
  readbackBudgetMs: shopifyReadbackBudgetMs,

  holdsRecords: false,
  rates: {},
  reconcileObjects: RECONCILE_OBJECTS,
  reconcile,
  checkSubscriptions,
  backfillObjects: BACKFILL_OBJECTS,
  backfill,
};
