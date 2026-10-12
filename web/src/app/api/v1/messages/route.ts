import { ApiError, assertSameSiteWrite, forPrincipal, jsonBody, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { parseSendInput } from "@/lib/messages";

export const dynamic = "force-dynamic";

/**
 * Sends a message (cma.send_message, messages.send): body { title, body?, urgency?, target } where the
 * target names exactly one of { "everyone": true }, { "teams": [keys] }, { "language": { "skill",
 * "minLevel" } } or { "users": [ids] }, optionally with "onlyClockedIn": true. The recipients are
 * resolved now, one delivery row each. A target that reaches nobody is a 400 (CMA04), an unknown
 * team, skill or person a 404 (CMA02), a sender without the permission a 403 (CMA06). Answers the
 * message id and the number of recipients.
 */
export async function POST(request: Request) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const input = parseSendInput(await jsonBody(request));
    if (!input.ok) throw new ApiError(400, input.code, input.message);
    return ok(await data().sendMessage(me, input.value), 201);
  });
}
