import { assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { checkSettingInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * Writes one tenant setting: { key, value } with value null to reset to the catalog default
 * (cma.set_tenant_setting, tenant.configure). Unknown key 404, a value outside the catalog 400.
 * Answers the setting as it now stands. Reading stays at GET /api/v1/settings.
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const { key, value } = checkSettingInput(await jsonBody(request));
    return ok(await data().setTenantSetting(me, key, value));
  });
}
