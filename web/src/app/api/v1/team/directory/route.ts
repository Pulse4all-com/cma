import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";

export const dynamic = "force-dynamic";

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const TOKEN_RE = /^[a-z0-9_]+$/;
const KEY_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * The people of the tenant with role, employer, teams and skills (migration 0004). Who is listed
 * (everyone for users.manage_all, the non-managing people for users.manage_agents) and who may
 * be edited is the database's answer in the same transaction (CMA06 → 403).
 */
export async function GET() {
  return forPrincipal(async (me) => ok(await data().listDirectory(me)));
}

function text(v: unknown, name: string, max: number, min = 1): string {
  if (typeof v !== "string" || v.trim().length < min || v.trim().length > max) {
    throw new ApiError(400, "invalid_person", `${name} must be ${min} to ${max} characters`);
  }
  return v.trim();
}

/**
 * Add a person: body { email, displayName, organisationKey, roleKey, loginSystem, loginId, timeZone? }.
 * The database adds user, login id and role in one statement, so a refusal writes nothing, and
 * answers the same id when the same person is added again (CMA03 for a different id or an
 * inactive person, 403 for a managing role without users.manage_all). Answers { userId }.
 * Shape checks only here; the rules are the function's.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const b = await jsonBody(request);
    const email = text(b.email, "email", 200).toLowerCase();
    if (!EMAIL_RE.test(email)) throw new ApiError(400, "invalid_person", "email must be an email address");
    const loginSystem = text(b.loginSystem, "loginSystem", 40).toLowerCase();
    if (!TOKEN_RE.test(loginSystem)) throw new ApiError(400, "invalid_person", "loginSystem must be a token");
    const loginId = text(b.loginId, "loginId", 200);
    if (/\s/.test(loginId)) throw new ApiError(400, "invalid_person", "loginId must not contain spaces");
    const organisationKey = text(b.organisationKey, "organisationKey", 60);
    const roleKey = text(b.roleKey, "roleKey", 60);
    if (!KEY_RE.test(organisationKey) || !/^[a-z_]+$/.test(roleKey)) throw new ApiError(400, "invalid_person", "organisationKey and roleKey must be keys");
    const timeZone = b.timeZone === undefined || b.timeZone === null || b.timeZone === "" ? null : text(b.timeZone, "timeZone", 60);
    const userId = await data().addPerson(me, {
      email, displayName: text(b.displayName, "displayName", 100), organisationKey, roleKey, loginSystem, loginId, timeZone,
    });
    return ok({ userId }, 201);
  });
}
