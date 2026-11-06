import { ApiError, teamRangeParams } from "@/lib/api/respond";
import { COURTESY_GROUPS, COURTESY_PERIODS, parseCourtesyFilter } from "@/lib/courtesy";
import type { CourtesyFilter, CourtesyGroup, CourtesyPeriod, HoursRange } from "@/lib/data";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the Courtesy route (addition 0009a): ?from&to (the period, at most 92 days), &period=week|month (the order
 * cohorts; week when left out), &group=day|week|month (per market and period; week when left out), and the optional &market (a
 * market code or unknown), &segment (a segment's code or unknown) and &state (not_reached, due, due_no_attempt, attempted,
 * not_due, completed or no_contact). Anything the database would refuse is a 400 here first.
 */
export function courtesyParams(sp: URLSearchParams): { range: HoursRange; period: CourtesyPeriod; group: CourtesyGroup; filter: CourtesyFilter } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const period = (sp.get("period") ?? "week") as CourtesyPeriod;
  if (!COURTESY_PERIODS.includes(period)) throw new ApiError(400, "invalid_period", "period must be week or month");
  const group = (sp.get("group") ?? "week") as CourtesyGroup;
  if (!COURTESY_GROUPS.includes(group)) throw new ApiError(400, "invalid_group", "group must be day, week or month");
  const { filter, problem } = parseCourtesyFilter(sp.get("market"), sp.get("segment"), sp.get("state"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "segment") throw new ApiError(400, "invalid_segment", "segment must be a segment's code or unknown");
  if (problem === "state") throw new ApiError(400, "invalid_state", "state must be not_reached, due, due_no_attempt, attempted, not_due, completed or no_contact");
  return { range: { from, to }, period, group, filter };
}
