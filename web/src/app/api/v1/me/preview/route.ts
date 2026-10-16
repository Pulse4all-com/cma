import { NextResponse } from "next/server";
import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody } from "@/lib/api/respond";
import { isRoleKey, PREVIEW_COOKIE, PREVIEW_MAX_AGE_S } from "@/lib/auth/preview";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

/**
 * POST /api/v1/me/preview with { roleKey: string | null } (16 October 2026): starts or ends the caller's
 * preview as a role (src/lib/auth/preview.ts). Only a caller whose real permissions hold users.manage_all
 * (the real principal, not the narrowed one: an admin previewing as an agent must be able to exit); the
 * key must be one of the tenant's roles (cma.roles(): the assignable roles, never the system role). Answers
 * 204 with the cookie set for 12 hours, or cleared for null. A non-admin or an unknown key is a 403 and
 * clears nothing. Same guards as every write: header x-cma-request: 1 and no cross-site requests.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    if (!me.canPreview) throw new ApiError(403, "not_permitted", "previewing needs users.manage_all");
    const { roleKey } = await jsonBody(request);
    if (roleKey !== null && !isRoleKey(roleKey)) throw new ApiError(400, "invalid_role", "roleKey must be a role key or null");
    if (roleKey !== null) {
      const roles = await data().listRoles(me);
      if (!roles.some((r) => r.key === roleKey)) throw new ApiError(403, "unknown_role", "not a role of this organisation");
    }
    const res = new NextResponse(null, { status: 204, headers: { "cache-control": "no-store" } });
    res.cookies.set(PREVIEW_COOKIE, roleKey ?? "", {
      httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: roleKey === null ? 0 : PREVIEW_MAX_AGE_S,
    });
    return res;
  }, { real: true });
}
