import { ApiError, teamRangeParams } from "@/lib/api/respond";
import type { CallsFilter, CallsGroup, HoursRange } from "@/lib/data";
import { MAX_REPORT_DAYS, parseCallsFilter, parseCallsGroup } from "@/lib/reports";

/**
 * The query of the Calls routes (addition 0008j): ?from&to (at most 92 days), &market (a market code or
 * unknown) and &line (a connection id ':' line ref), each optional, and for the overview and the tag use
 * &group=day|week|market|line (day when left out). Anything the database would refuse is a 400 here first.
 */
export function callsParams(sp: URLSearchParams, withGroup: boolean): { range: HoursRange; filter: CallsFilter; group: CallsGroup } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseCallsFilter(sp.get("market"), sp.get("line"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "line") throw new ApiError(400, "invalid_line", "line must be a connection id and a line ref");
  const group = withGroup && sp.has("group") ? parseCallsGroup(sp.get("group")) : "day";
  if (!group) throw new ApiError(400, "invalid_group", "group must be day, week, market or line");
  return { range: { from, to }, filter, group };
}
