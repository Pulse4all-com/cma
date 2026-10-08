import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkLinkInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** Every app link of the tenant, active or retired, for tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listConfigAppLinks(me)));
}

/** Adds or changes a link: { key, label, address, permissionKey, sortOrder }; https only (400), unknown permission 404. Answers the list */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    await data().upsertAppLink(me, checkLinkInput(await jsonBody(request)));
    return ok(await data().listConfigAppLinks(me));
  });
}
