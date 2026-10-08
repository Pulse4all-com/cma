import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkStatusInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The tenant's work statuses as configuration (migration 0005a): every status with its four flags,
 * the default, active or retired, and its usage; for people holding tenant.configure (CMA06 → 403).
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listConfigStatuses(me)));
}

/**
 * Adds or changes a status: { key, name, isWorking, isProductive, isPaid, isBillable, sortOrder }.
 * A retired key is reactivated. The database refuses changed flags on a status with time behind
 * it (409) and a non-working default (409). Answers the list.
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().upsertConfigStatus(me, checkStatusInput(await jsonBody(request)));
    return ok(await data().listConfigStatuses(me));
  });
}
