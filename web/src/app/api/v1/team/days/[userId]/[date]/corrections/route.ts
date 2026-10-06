import { ApiError, assertSameSiteWrite, dateParam, forPrincipal, jsonBody, ok, uuidParam } from "@/lib/api/respond";
import { data, type CorrectionChange, type TimeEventKind } from "@/lib/data";

export const dynamic = "force-dynamic";

type Params = { params: Promise<{ userId: string; date: string }> };

const KINDS: readonly TimeEventKind[] = ["start", "status", "end", "void"];
/** ISO 8601 with an explicit offset: during the autumn clock change one local hour occurs twice */
const AT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:\d{2})$/;
const ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_CHANGES = 100;

function invalid(message: string): never {
  throw new ApiError(400, "invalid_correction", message);
}

/** Shape checks only, for clear 400s; the rules (order, the day's bounds, own day) are the database's */
function parseChanges(raw: unknown): CorrectionChange[] {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_CHANGES) {
    invalid(`changes must be an array of 1 to ${MAX_CHANGES} changes`);
  }
  return raw.map((c, i) => {
    if (!c || typeof c !== "object" || Array.isArray(c)) invalid(`change ${i + 1} must be an object`);
    const { kind, at, statusKey, supersedes } = c as Record<string, unknown>;
    if (typeof kind !== "string" || !(KINDS as readonly string[]).includes(kind)) {
      invalid(`change ${i + 1}: kind must be start, status, end or void`);
    }
    const out: CorrectionChange = { kind: kind as TimeEventKind };
    if (kind !== "void") {
      if (typeof at !== "string" || !AT_RE.test(at) || Number.isNaN(Date.parse(at))) {
        invalid(`change ${i + 1}: at must be an ISO 8601 time with an offset`);
      }
      out.at = at;
    }
    if (kind === "start" || kind === "status") {
      if (typeof statusKey !== "string" || statusKey.length < 1 || statusKey.length > 100) {
        invalid(`change ${i + 1}: statusKey must be a key from /api/v1/me/statuses`);
      }
      out.statusKey = statusKey;
    }
    if (supersedes !== undefined && supersedes !== null) {
      if (typeof supersedes !== "string" || !ID_RE.test(supersedes)) invalid(`change ${i + 1}: supersedes must be an event id`);
      out.supersedes = supersedes.toLowerCase();
    }
    if (kind === "void" && !out.supersedes) invalid(`change ${i + 1}: void needs the event it cancels`);
    return out;
  });
}

/**
 * Correct one person's day: body { "reason": "…", "changes": [ { kind, at, statusKey, supersedes } ] }.
 * On a date without a day this is Add day, and the first change must be the start. The caller is
 * the approver (V1). Answers { day, events } as the day now stands.
 *
 * 400 invalid shape or edit, 403 without workday.team or for one's own day, 404 unknown person or
 * status. Same guards as the other writes: header x-cma-request: 1 and no cross-site requests.
 */
export async function POST(request: Request, { params }: Params) {
  return forPrincipal(async (me) => {
    assertSameSiteWrite(request);
    const p = await params;
    const userId = uuidParam(p.userId, "userId");
    const date = dateParam(p.date, "date");
    const body = await jsonBody(request);
    const reason = typeof body.reason === "string" ? body.reason.trim() : "";
    if (reason.length < 3 || reason.length > 500) {
      throw new ApiError(400, "invalid_reason", "reason must be 3 to 500 characters");
    }
    const changes = parseChanges(body.changes);
    return ok(await data().correctWorkday(me, userId, date, { reason, changes }));
  });
}
