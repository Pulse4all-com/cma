import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission, uuidParam } from "@/lib/api/respond";
import { checkSubscriptionVariantInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The variant mapping of a subscriptions connection (addition 0009ze, brief B39c C.1), tenant.configure:
 * GET ?connection=<id>: the connection's product variants with their mapping (the store's catalog texts: merchant text,
 * never a customer's; the active lines; unmapped variants on an active line first), the tenant's device models and its
 * propositions. 404 for a connection that is not a subscriptions connection of the tenant
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    const connectionId = uuidParam(new URL(request.url).searchParams.get("connection"), "connection");
    return ok(await data().getSubscriptionVariants(me, connectionId));
  });
}

/**
 * PUT { connectionId, variantSourceId, lineKind, modelKey, devicesPerUnit, proposition }: one variant's mapping
 * (cma.set_subscription_variant_mapping, audited); a lineKind of null removes it. Answers the connection's variants again
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const input = checkSubscriptionVariantInput(await jsonBody(request));
    await data().setSubscriptionVariant(me, input);
    return ok(await data().getSubscriptionVariants(me, input.connectionId));
  });
}
