import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkAliasInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** { alias, code }: adds or moves an alias (set_market_alias); code null removes it (remove_market_alias, unknown 404). Answers the markets */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const { alias, code } = checkAliasInput(await jsonBody(request));
    await data().setMarketAlias(me, alias, code);
    return ok(await data().getMarkets(me));
  });
}
