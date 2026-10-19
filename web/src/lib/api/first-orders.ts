import { ApiError, teamRangeParams } from "@/lib/api/respond";
import type { FirstOrderFilter, FirstOrderGroup, HoursRange } from "@/lib/data";
import { parseFirstOrderFilter, parseFirstOrderGroup } from "@/lib/first-orders";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the First orders routes (addition 0008u): ?from&to (at most 92 days), &market (a market code or
 * unknown) and &level (one of the six evidence levels or self_service), each optional, and &group=day|week|market|level
 * (day when left out). Anything the database would refuse is a 400 here first.
 */
export function firstOrderParams(sp: URLSearchParams): { range: HoursRange; filter: FirstOrderFilter; group: FirstOrderGroup } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseFirstOrderFilter(sp.get("market"), sp.get("level"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "level") throw new ApiError(400, "invalid_level", "level must be lead_deal, conversation, email, phone_match, attempt, known_contact or self_service");
  const group = sp.has("group") ? parseFirstOrderGroup(sp.get("group")) : "day";
  if (!group) throw new ApiError(400, "invalid_group", "group must be day, week, market or level");
  return { range: { from, to }, filter, group };
}
