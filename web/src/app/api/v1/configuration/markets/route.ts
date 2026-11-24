import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkMarketInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The markets with their aliases, the office hours and the holidays (addition 0008e). tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    return ok(await data().getMarkets(me));
  });
}

/**
 * { code, name, timeZone, languageCode, currency, languageSkillKey, minLanguageLevel, sortOrder, active, hoursMarketCode? }:
 * upsert_market, set_market_hours_market (addition 0009zo: left out keeps the mapping; null or the market's own code makes
 * it an hours market) and set_market_status, in one transaction; UK 400 (use GB), an unknown zone 400, an unknown skill or
 * market 404, a target that is no active hours market 400, a market others book under or a person's Default market 409
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    const { input, active } = checkMarketInput(await jsonBody(request));
    await data().upsertMarket(me, input, active);
    return ok(await data().getMarkets(me));
  });
}
