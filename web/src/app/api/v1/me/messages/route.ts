import { ApiError, forPrincipal, ok } from "@/lib/api/respond";
import { data } from "@/lib/data";
import { parseInboxQuery } from "@/lib/messages";

export const dynamic = "force-dynamic";

/**
 * The caller's own messages (migration 0008), newest first, with their unread count: ?since=<ISO instant>
 * lists only messages created after it (the open Workspace's poll), ?limit= at most 200. Returning
 * a message for the first time sets its delivered time. Own deliveries only: no user parameter.
 */
export async function GET(request: Request) {
  return forPrincipal(async (me) => {
    const sp = new URL(request.url).searchParams;
    const q = parseInboxQuery(sp.get("since"), sp.get("limit"));
    if (!q.ok) throw new ApiError(400, q.code, q.message);
    return ok(await data().listMyMessages(me, q.value.since, q.value.limit));
  });
}
