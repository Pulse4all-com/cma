import { assertSameSiteWrite, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * End the caller's own workday today: the same data path as the End workday button.
 * Ending an ended day returns it unchanged; no day today is a 404.
 * Requires the header x-cma-request: 1 (cross-site request guard).
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    return ok(await data().endWorkday(me, new Date().toISOString()));
  });
}
