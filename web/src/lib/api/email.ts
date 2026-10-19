import { ApiError, teamRangeParams } from "@/lib/api/respond";
import type { EmailFilter, EmailGroup, HoursRange } from "@/lib/data";
import { parseEmailFilter, parseEmailGroup } from "@/lib/email";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the Email routes (addition 0008t): ?from&to (at most 92 days), &market (a market code or
 * unknown), &inbox and &account (each a connection id ':' source id), each optional, and &group=day|week
 * (day when left out). Anything the database would refuse is a 400 here first.
 */
export function emailParams(sp: URLSearchParams): { range: HoursRange; filter: EmailFilter; group: EmailGroup } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseEmailFilter(sp.get("market"), sp.get("inbox"), sp.get("account"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "inbox") throw new ApiError(400, "invalid_inbox", "inbox must be a connection id and an inbox id");
  if (problem === "account") throw new ApiError(400, "invalid_account", "account must be a connection id and a mailbox id");
  const group = sp.has("group") ? parseEmailGroup(sp.get("group")) : "day";
  if (!group) throw new ApiError(400, "invalid_group", "group must be day or week");
  return { range: { from, to }, filter, group };
}
