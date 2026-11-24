import { forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * The tenant's active hours markets (addition 0009zo, D3): the markets My day's select offers, in the markets' order,
 * as { code, name, isActive }. Configuration only (codes and names), for anyone signed in to the tenant, as the status
 * list; POST /api/v1/me/status takes one as hoursMarket.
 */
export async function GET() {
  return forPrincipal(async (me) => ok((await data().listMyDayChoices(me)).hoursMarkets));
}
