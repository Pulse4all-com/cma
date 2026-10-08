import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkAbsenceInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Every absence type, active or retired, for tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => {
    await data().listConfigStatuses(me);   // the configuration gate; the absence catalog itself is readable by any person
    return ok(await data().listAbsenceTypes(me));
  });
}

/** Adds or changes an absence type: { key, name, isPaid, sortOrder }; a retired key is reactivated. Answers the list */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().upsertAbsenceType(me, checkAbsenceInput(await jsonBody(request)));
    return ok(await data().listAbsenceTypes(me));
  });
}
