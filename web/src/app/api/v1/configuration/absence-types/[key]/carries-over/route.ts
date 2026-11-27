import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkCarriesOver, checkKey } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ key: string }> };

/** Whether Copy week and Save as standard week take this absence type (D10): body { carriesOver }. Answers the list */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const key = checkKey((await params).key, /^[a-z0-9_]+$/);
    await data().setAbsenceCarriesOver(me, key, checkCarriesOver(await jsonBody(request)));
    return ok(await data().listAbsenceTypes(me));
  });
}
