import { flashRowsParams } from "@/lib/api/flash";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { overviewOf } from "@/lib/flash";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The records behind a Flash figure (cma.flash_rows, addition 0008zn): ?overview, &market, &from and &to (a flow's
 * period), &measure (a count measure), a filter per dim as f_<dim>, &sort (the overview's whitelist) and &dir, &limit (1
 * to the tenant's flash.file_max_rows; 500 when left out) and &offset; with &asOf a past month end's frozen list
 * (customers, subscriptions, installed_base; 404 for any other date). `total` (every record before the limit) and
 * `rows`: ids, statuses, codes, amounts with their currency and the CRM's links; on open deals and open tickets a
 * pipeline's (queue's) and a stage's label beside its id (pipeline_label, queue_label, stage_label: the label the CMA
 * holds for the connection's pipeline and stage, the id where it holds none). Needs reports.view or
 * performance.team, here and again in the database. Never a name, email, phone or address. Every read is recorded in
 * the audit log as a file read is (cma.flash_file_record, part rows: who, which overview, which filters, how many
 * rows; never a row), before the rows are sent.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const q = flashRowsParams(new URL(request.url).searchParams);
    const def = overviewOf(q.overview)!;
    const list = await data().getFlashRows(me, q);
    // every bulk read of records is in the audit log, as a file is (decision 7): the same record, before the rows go out
    await data().recordFlashFile(me, { overview: def.key, part: "rows", filters: q.filters, market: q.market, asOf: q.asOf,
      from: def.kind === "flow" ? q.from : null, to: def.kind === "flow" ? q.to : null, rows: list.rows.length });
    return ok(list);
  });
}
