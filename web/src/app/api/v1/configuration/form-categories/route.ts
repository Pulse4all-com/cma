import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkFormCategoryInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The tenant's form categories (addition 0008p) with how many forms carry each. tenant.configure, reports.view or performance.team */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure", "reports.view", "performance.team"]);
    return ok(await data().getFormCategories(me));
  });
}

/** { code, name, sortOrder, isActive }: adds or renames a category and switches it on or off (set_form_category, set_form_category_status). tenant.configure. Answers the list */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    await data().setFormCategory(me, checkFormCategoryInput(await jsonBody(request)));
    return ok(await data().getFormCategories(me));
  });
}
