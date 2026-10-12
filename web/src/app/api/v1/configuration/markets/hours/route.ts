import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkHoursInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** { market, days: [ { weekday, hours } ] }: weekdays' office hours of a market or * in one transaction (set_business_hours); "" closes a day. Answers the markets */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const { market, days } = checkHoursInput(await jsonBody(request));
    await data().setOfficeHours(me, market, days);
    return ok(await data().getMarkets(me));
  });
}
