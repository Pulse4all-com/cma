import { formsParams } from "@/lib/api/forms";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The forms report (cma.forms_report, addition 0008p) for ?from&to (at most 92 days), &group=day|week (day
 * when left out; anything else 400) and the optional &market (a code or unknown), &category (a code or
 * none) and &form (connection id ':' form id) filters: every polled form's submissions per day or week, form
 * and market (the form's market, else the market field's answer, else the contact's country, else unknown)
 * with the contact resolution split; `totals` per form and market over the period, `previous` the same over
 * the previous equal period, like for like; `historyStart` the business date of the tenant's earliest stored
 * submission; the categories, forms and markets for the filters; and `forms` (false: no source has a form,
 * and no rows, never 0). Counted in Intake or not makes no difference here. Needs reports.view or
 * performance.team, here and again in the database. Form names, codes and counts only: no submission, no
 * contact, no email.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, group } = formsParams(new URL(request.url).searchParams);
    return ok(await data().getFormsReport(me, range, group, filter));
  });
}
