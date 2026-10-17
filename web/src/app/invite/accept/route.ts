import { getIdentity } from "@/lib/auth/identity";
import { data } from "@/lib/data";
import { CmaDbError } from "@/lib/data/errors";
import { INVITE_TOKEN_RE } from "@/lib/invitations";
import { isSameOriginPost } from "@/lib/origin";

/**
 * POST /invite/accept (addition 0008l): the Accept button of /invite/<token>, a plain form post with the
 * token in the body (not in this address). Same-origin only, as /logout/end; the identity is the one
 * proxy.ts verified (IAP's signed token), its id, provider and address passed to cma.accept_invitation,
 * which binds the id only when the verified address is the invited one. Accepted, or already a person
 * there: 303 to Welcome. Otherwise 303 back to the invitation, which shows why. Locations are relative and
 * built from a token of the one valid shape only, so this never redirects anywhere else. Nothing about the
 * token, the address or the identity is logged.
 */
export async function POST(request: Request) {
  if (!isSameOriginPost({
    secFetchSite: request.headers.get("sec-fetch-site"),
    origin: request.headers.get("origin"),
    host: request.headers.get("host"),
  })) return new Response("Forbidden", { status: 403, headers: { "cache-control": "no-store" } });

  const identity = await getIdentity();
  if (!identity) return new Response("Not authenticated", { status: 401, headers: { "cache-control": "no-store" } });

  const form = await request.formData().catch(() => null);
  const token = form?.get("token");
  if (typeof token !== "string" || !INVITE_TOKEN_RE.test(token)) {
    return new Response("Invalid invitation", { status: 400, headers: { "cache-control": "no-store" } });
  }

  let result;
  try {
    result = await data().acceptInvitation(identity, token);
  } catch (e) {
    if (e instanceof CmaDbError) {
      console.error(`[cma-invite] accept failed: ${e.sqlState}`);
      return new Response("Please try again in a moment", { status: 503, headers: { "cache-control": "no-store" } });
    }
    throw e;
  }
  const location = result === "accepted" || result === "already_member" ? "/" : `/invite/${token}`;
  return new Response(null, { status: 303, headers: { Location: location, "cache-control": "no-store" } });
}
