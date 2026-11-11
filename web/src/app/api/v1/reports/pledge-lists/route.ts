import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { isPledgeCheck, PLEDGE_CHECK_ROWS, PLEDGE_PERMISSIONS } from "@/lib/pledges";

export const dynamic = "force-dynamic";

/**
 * Assets → Pledge lists (cma.pledge_page, addition 0009j): `files` (every quarter file: valuationDate, takenAt, loans,
 * devices), `today` (per active loan with devices: number, lenderLabel, devices, inStorage and the sums acquisitionValue,
 * currentValue, receipts as decimal text), `checks` (each check's device count), `unmappedLanguages`, `quarter`,
 * `fileNamePrefix`, `isSetUp`; with &check (one of the checks) and &limit (1 to 1000; 500 when left out) also `checkRows`
 * (the check's serials, record ids and values). Needs pledges.view, here and again in the database. Ids, codes, dates and
 * amounts; the lender label is the loan catalog's.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, PLEDGE_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const check = sp.get("check");
    if (check !== null && !isPledgeCheck(check)) throw new ApiError(400, "invalid_check", "check must be one of the checks before the next file");
    const limitText = sp.get("limit");
    const limit = limitText === null ? PLEDGE_CHECK_ROWS : Number(limitText);
    if (!Number.isInteger(limit) || limit < 1 || limit > 1000 || (limitText !== null && !/^\d{1,4}$/.test(limitText))) {
      throw new ApiError(400, "invalid_limit", "limit must be a whole number from 1 to 1000");
    }
    return ok(await data().getPledgePage(me, check, limit));
  });
}
