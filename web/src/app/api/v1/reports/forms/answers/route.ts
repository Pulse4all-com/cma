import { formsParams } from "@/lib/api/forms";
import { forPrincipal, ok, requireAnyPermission } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { REPORT_PERMISSIONS } from "@/lib/reports";

export const dynamic = "force-dynamic";

/**
 * The forms' answers (cma.forms_answers, addition 0008p) for ?from&to (at most 92 days), the filters of the
 * forms report and the optional &field and &value: submissions per form, market, kept choice field and option
 * value (a multiple-checkboxes answer under each of its values), `period` current or previous (the previous
 * equal period, like for like). Kept choice fields only: never a free-text answer. Needs reports.view or
 * performance.team, here and again in the database.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, REPORT_PERMISSIONS);
    const { range, filter, field, value } = formsParams(new URL(request.url).searchParams);
    return ok(await data().getFormsAnswers(me, range, filter, field, value));
  });
}
