import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { hoursMarketOrNull } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ userId: string }> };

/**
 * A person's Default market (addition 0009zo, D4): body { "hoursMarket": "<code>" | null }. The hours market the person's
 * clock-in books under; null clears it. As the other People writes, the database decides whether the caller manages the
 * person (403); a market the tenant lacks is a 404, one that is no active hours market a 400. Answers the person.
 */
export async function PUT(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const userId = uuidParam((await params).userId, "userId");
    const b = await jsonBody(request);
    // The key is required, null clears: a body without it (or with a misspelt key) never clears a Default market
    if (!("hoursMarket" in b)) throw new ApiError(400, "invalid_hours_market", "hoursMarket is required: a market code, or null to clear");
    const hoursMarket = hoursMarketOrNull(b.hoursMarket, "hoursMarket");
    await data().setPersonDefaultHoursMarket(me, userId, hoursMarket);
    return ok((await data().listDirectory(me)).find((p) => p.userId === userId) ?? null);
  });
}
