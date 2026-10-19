import { ApiError, teamRangeParams } from "@/lib/api/respond";
import { parseAttemptFilter, parseAttemptGroup } from "@/lib/attempts";
import type { AttemptFilter, AttemptGroup, HoursRange } from "@/lib/data";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the Attempts routes (addition 0008y): ?from&to (at most 92 days), &market (a market code or unknown),
 * &pipeline (a connection id and a pipeline id joined by ':') and &scope (lead, the default, or counted), each
 * optional, and &group=day|week|market|pipeline (day when left out). Anything the database would refuse is a 400
 * here first.
 */
export function attemptParams(sp: URLSearchParams): { range: HoursRange; filter: AttemptFilter; group: AttemptGroup } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseAttemptFilter(sp.get("market"), sp.get("pipeline"), sp.get("scope"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "pipeline") throw new ApiError(400, "invalid_pipeline", "pipeline must be a connection id and a pipeline id joined by a colon");
  if (problem === "scope") throw new ApiError(400, "invalid_scope", "scope must be lead or counted");
  const group = sp.has("group") ? parseAttemptGroup(sp.get("group")) : "day";
  if (!group) throw new ApiError(400, "invalid_group", "group must be day, week, market or pipeline");
  return { range: { from, to }, filter, group };
}
