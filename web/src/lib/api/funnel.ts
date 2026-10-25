import { ApiError, teamRangeParams } from "@/lib/api/respond";
import { parseFunnelFilter, parseFunnelGroup } from "@/lib/funnel";
import type { FunnelFilter, FunnelGroup, HoursRange } from "@/lib/data";
import { MAX_REPORT_DAYS } from "@/lib/reports";

/**
 * The query of the Funnel and Cancellations routes (addition 0008zb): ?from&to (at most 92 days), &market (a market code
 * or unknown), &pipeline (a connection id and a lead pipeline's id joined by ':') and &source (a source channel, 1 to 100
 * characters), each optional, and &group=week|day (week when left out) where the route groups by time. Cancellations and
 * Reviews (addition 0008ze) take the market only: a pipeline or a source there is a 400. Anything the database would
 * refuse is a 400 here first.
 */
export function funnelParams(sp: URLSearchParams, o: { marketOnly?: boolean } = {}): { range: HoursRange; filter: FunnelFilter; group: FunnelGroup } {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  if (o.marketOnly && (sp.has("pipeline") || sp.has("source"))) {
    throw new ApiError(400, "invalid_filter", "cancellations and reviews take the market filter only");
  }
  const { filter, problem } = parseFunnelFilter(sp.get("market"), sp.get("pipeline"), sp.get("source"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "pipeline") throw new ApiError(400, "invalid_pipeline", "pipeline must be a connection id and a pipeline id joined by a colon");
  if (problem === "source") throw new ApiError(400, "invalid_source", "source must be 1 to 100 characters without control characters");
  const group = sp.has("group") ? parseFunnelGroup(sp.get("group")) : "week";
  if (!group) throw new ApiError(400, "invalid_group", "group must be week or day");
  return { range: { from, to }, filter, group };
}
