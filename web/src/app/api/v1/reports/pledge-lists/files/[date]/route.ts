import { ApiError, forPrincipal, requireAnyPermission, xlsxFile } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { fileDateParam, PLEDGE_PERMISSIONS, pledgeBook, pledgeFileName } from "@/lib/pledges";
import { xlsxFile as bookBytes } from "@/lib/xlsx";

export const dynamic = "force-dynamic";
type Params = { params: Promise<{ date: string }> };

/**
 * A pledge-list file as .xlsx (addition 0009j; D1: exactly the original file's tabs, columns, headers and formats):
 * /files/{yyyy-mm-dd} the quarter file of that valuation date as it was taken (frozen: the same bytes at any later time),
 * /files/today today's version, valued at the tenant's today and named …_preview. 400 for a date that is no quarter's
 * first day, 404 for a date without a file or a today without a pledged device, at most 50,000 rows (the database
 * refuses more: 400). Needs pledges.view, here and again in the database. No name, address or email of a customer
 * exists to write; the lender labels are the loan catalog's (the tab names).
 */
export async function GET(_request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, PLEDGE_PERMISSIONS);
    const which = fileDateParam((await params).date);
    if (which === null) throw new ApiError(400, "invalid_date", "a file is today or a quarter's first day as YYYY-MM-DD");
    const file = await data().getPledgeFile(me, which === "today" ? null : which);
    const valuationDate = file.rows[0]?.valuationDate ?? null;
    const book = valuationDate ? pledgeBook(file.rows, valuationDate) : null;
    if (!book || !valuationDate) throw new ApiError(404, "no_pledges", "no pledged device to write");
    return xlsxFile(bookBytes(book), pledgeFileName(file.fileNamePrefix, valuationDate, which === "today"));
  });
}
