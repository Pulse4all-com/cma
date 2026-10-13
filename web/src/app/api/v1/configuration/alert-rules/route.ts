import { assertSameSiteWrite, forPrincipal, jsonBody, ok, requireAnyPermission } from "@/lib/api/respond";
import { checkAlertRuleInput } from "@/lib/api/configuration";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/** The alert rules of both triggers with their alerts, and the pipelines a rule can name (cma.message_rules, addition 0008e). tenant.configure */
export async function GET() {
  return forPrincipal(async (me) => {
    requireAnyPermission(me, ["tenant.configure"]);
    return ok(await data().getAlertRules(me));
  });
}

/**
 * Adds or changes a rule by name: { name, trigger, recordType, pipelineIds, urgency, maxAgeMinutes } and, for
 * record_created, { audiencePermission, matchLanguage, onlyClockedIn, fallbackPermission }. A name another rule
 * of the other trigger holds 409, an unknown permission 404. Answers the rules
 */
export async function PUT(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    requireAnyPermission(me, ["tenant.configure"]);
    await data().upsertAlertRule(me, checkAlertRuleInput(await jsonBody(request)));
    return ok(await data().getAlertRules(me));
  });
}
