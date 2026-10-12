import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkHolidayInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** { market, day, name }: adds or renames a holiday (set_business_holiday); name null removes it (unknown 404). Answers the markets */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const { market, day, name } = checkHolidayInput(await jsonBody(request));
    await data().setHoliday(me, market, day, name);
    return ok(await data().getMarkets(me));
  });
}
