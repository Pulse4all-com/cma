/**
 * Preview as role (16 October 2026, backlog: an admin sees what a role sees; never impersonation).
 *
 * Only a person whose real permissions hold users.manage_all may preview. The preview narrows: the
 * permissions shown become the intersection of the real set and the previewed role's set, so it can
 * never add a permission, and an unknown role key is no preview at all. The person stays themselves:
 * the user id, the tenant, the day and the hours are their own, and the audit's actor is the real
 * user. Because pages and the JSON API share getAccess() (lib/auth/identity), a previewing admin gets
 * the role's screens and the app's 403 on the routes the role may not call, while the database still
 * runs every call with the real permissions (cma.current_user_id() is the real user): a preview can
 * never grant anything and never changes what the database does.
 *
 * Pure and without runtime imports, so verify/preview.mjs tests the narrowing without a server. The
 * cookie is read in getAccess(); the route POST /api/v1/me/preview sets and clears it.
 */
import type { Principal } from "./identity";

/** The cookie that holds the previewed role key: httpOnly, secure, samesite=lax, path /, 12 hours */
export const PREVIEW_COOKIE = "cma-preview-role";
/** A preview must not outlive the day */
export const PREVIEW_MAX_AGE_S = 12 * 60 * 60;
/** The real permission that allows previewing */
export const PREVIEW_PERMISSION = "users.manage_all";
/** Role keys as the tenant's roles are keyed (lower-case slugs); anything else is ignored, never trusted */
const ROLE_KEY_RE = /^[a-z0-9_-]{1,64}$/;

/** A role as the select and the narrowing need it: cma.roles() gives key, name and permissions */
export interface PreviewRole {
  key: string;
  name: string;
  permissions: readonly string[];
}

/** True when these (real) permissions allow a preview */
export function mayPreview(permissions: readonly string[]): boolean {
  return permissions.includes(PREVIEW_PERMISSION);
}

/** A well-formed role key, from the cookie or a request body */
export function isRoleKey(value: unknown): value is string {
  return typeof value === "string" && ROLE_KEY_RE.test(value);
}

/** The intersection, in the order of the real set, each key once: never a permission the person lacks */
export function narrowPermissions(real: readonly string[], role: readonly string[]): string[] {
  const allowed = new Set(role);
  return [...new Set(real)].filter((p) => allowed.has(p));
}

/**
 * The principal as the screens see it: canPreview from the real permissions (so the control still renders
 * while previewing), and, when a known role is previewed by someone who may, the narrowed permissions and
 * the preview's role. A non-admin, an ill-formed or unknown key or no key at all leaves the permissions as
 * they are and the preview null.
 */
export function applyPreview<P extends Pick<Principal, "permissions" | "preview" | "canPreview">>(
  real: P,
  roleKey: unknown,
  roles: readonly PreviewRole[],
): P {
  const canPreview = mayPreview(real.permissions);
  const own: P = { ...real, canPreview, preview: null };
  if (!canPreview || !isRoleKey(roleKey)) return own;
  const role = roles.find((r) => r.key === roleKey);
  if (!role) return own;
  return {
    ...own,
    permissions: narrowPermissions(real.permissions, role.permissions),
    preview: { roleKey: role.key, roleName: role.name },
  };
}
