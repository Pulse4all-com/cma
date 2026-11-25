import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkAssignmentTypeInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Every assignment type, active or retired (addition 0009zx), for tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => {
    await data().listConfigStatuses(me);   // the configuration gate; the catalog itself is readable by any person
    return ok(await data().listAssignmentTypes(me));
  });
}

/**
 * Adds or changes an assignment type by its code: { code, name, kind, statusKey, isExtra, sortOrder, active } (D2). A work
 * type books a working status, a pause one that is not working, an extra type none (400); an unknown status is 404.
 * Answers the list
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().upsertAssignmentType(me, checkAssignmentTypeInput(await jsonBody(request)));
    return ok(await data().listAssignmentTypes(me));
  });
}
