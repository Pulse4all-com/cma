import { ApiError, teamRangeParams } from "@/lib/api/respond";
import { parseCohortPeriod, parseCohortSplit } from "@/lib/cohorts";
import type { CohortPeriod, CohortSplit, FunnelFilter, HoursRange } from "@/lib/data";
import { parseFunnelFilter } from "@/lib/funnel";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the Lead cohorts route (addition 0008zm): the Funnel's (?from&to of the deals' creation, at most 92 days, and the
 * optional &market, &pipeline and &source, as lib/api/funnel takes them), &period=week|month (week when left out) and
 * &split=none|market|source (none when left out). Anything the database would refuse is a 400 here first.
 */
export function leadCohortParams(sp: URLSearchParams): { range: HoursRange; filter: FunnelFilter; period: CohortPeriod; split: CohortSplit } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseFunnelFilter(sp.get("market"), sp.get("pipeline"), sp.get("source"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "pipeline") throw new ApiError(400, "invalid_pipeline", "pipeline must be a connection id and a pipeline id joined by a colon");
  if (problem === "source") throw new ApiError(400, "invalid_source", "source must be 1 to 100 characters without control characters");
  const period = sp.has("period") ? parseCohortPeriod(sp.get("period")) : "week";
  if (!period) throw new ApiError(400, "invalid_period", "period must be week or month");
  const split = sp.has("split") ? parseCohortSplit(sp.get("split")) : "none";
  if (!split) throw new ApiError(400, "invalid_split", "split must be none, market or source");
  return { range: { from, to }, filter, period, split };
}
