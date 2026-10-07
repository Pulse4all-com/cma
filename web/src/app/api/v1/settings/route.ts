import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The tenant's effective settings (cma.tenant_settings): every setting the catalog knows, with the
 * tenant's own value or the default and whether it is the default. Any person of the tenant; the
 * values are formats, not personal data. Changing them comes with the configuration screens.
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listSettings(me)));
}
