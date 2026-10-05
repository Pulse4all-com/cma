import { forPrincipal, ok } from "@/lib/api/respond";

export const dynamic = "force-dynamic";

/** Who the caller is to the CMA: their own principal, nothing about anyone else */
export async function GET() {
  return forPrincipal(async (me) =>
    ok({
      userId: me.userId,
      displayName: me.displayName,
      tenantId: me.tenantId,
      tenantName: me.tenantName,
      organisationName: me.organisationName,
      roleKey: me.roleKey,
      timeZone: me.timeZone,
      locale: me.locale,
    }),
  );
}
