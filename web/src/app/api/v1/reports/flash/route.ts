import { flashParams } from "@/lib/api/flash";
import { ApiError, forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { FLASH_ADDRESS, FLASH_DOCUMENT_FILTERS, filterDocument, overviewOf } from "@/lib/flash";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * Reports > Flash (addition 0008zn). Without ?overview the landing (cma.flash_page): per overview its headline as stored
 * for &asOf (a business date with a snapshot) or, for now, the figure to compare with (the latest snapshot), the sources'
 * last successful reads, the open watch findings, the markets and the first and latest snapshot dates; a date without a
 * snapshot answers snapshotMissing with the nearest dates. With ?overview the overview's document (cma.flash_overview):
 * its totals, every grouping set's rows (dims and measures; an amount per currency, never summed across currencies), the
 * sources, the labels, the settings, live or as of &asOf; a flow over &from to &to. With &part=headline only the live
 * headline of one overview (cma.flash_headline), as each landing card asks for it. &market narrows any of them; on the
 * installed base &f_model narrows the document to one model as the page does (addition 0008zy). Needs
 * reports.view or performance.team, here and again in the database. Team figures only: ids, codes, counts and amounts.
 * Any other &part is a 400 (invalid_part).
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const sp = new URL(request.url).searchParams;
    const q = flashParams(sp);
    const part = sp.get("part");
    if (part !== null && part !== "" && part !== "headline") throw new ApiError(400, "invalid_part", "part must be headline, or left out");
    if (part === "headline") {
      const h = flashParams(sp, { overviewRequired: true });
      return ok(await data().getFlashHeadline(me, h.overview!, h.market, h.from, h.to));
    }
    if (q.overview) {
      const doc = await data().getFlashOverview(me, q.overview, q.market, q.asOf, q.from, q.to);
      // the Installed base's Model filter (f_model, addition 0008zy): the document narrowed as the page shows it, with what
      // the filter cannot narrow (unavailableMeasures, unavailableSets: never a figure, never the unfiltered one)
      const def = overviewOf(q.overview)!;
      const dim = FLASH_DOCUMENT_FILTERS[def.key];
      const value = dim ? sp.get(`${FLASH_ADDRESS.filterPrefix}${dim}`) : null;
      if (dim && value !== null && value !== "") {
        if (value.length > 100) throw new ApiError(400, "invalid_filter", `f_${dim} is 1 to 100 characters`);
        const narrowed = filterDocument(def, doc.totals, doc.rows, dim, value);
        return ok({ ...doc, totals: narrowed.totals, rows: narrowed.rows, filter: { [dim]: value },
          unavailableMeasures: narrowed.unavailableMeasures, unavailableSets: narrowed.unavailableSets });
      }
      return ok(doc);
    }
    return ok(await data().getFlashPage(me, q.market, q.asOf, q.from, q.to));
  });
}
