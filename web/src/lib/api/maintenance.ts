import { ApiError } from "@/lib/api/respond";
import { bucketProblem, MAINTENANCE_DEFAULT_HORIZON, MAINTENANCE_FILE_ROWS, MAINTENANCE_LIST_ROWS, parseScope, parseView } from "@/lib/maintenance";
import type { MaintenanceFilter, MaintenanceView } from "@/lib/data";

/**
 * The query of the Maintenance routes (addition 0008zi): ?from (the first day of a month, YYYY-MM-01; the database
 * refuses one before the tenant's current month), &months (1 to 24; 12 when left out), &market (a market code or
 * unknown), &model (a model's key or unknown) and &scope (field or stock), each optional but from. Anything the database
 * would refuse for its form is a 400 here first.
 */
export function maintenanceParams(sp: URLSearchParams): MaintenanceFilter {
  const from = sp.get("from");
  if (!from || !/^\d{4}-\d{2}-01$/.test(from) || Number.isNaN(Date.parse(`${from}T00:00:00Z`))) {
    throw new ApiError(400, "invalid_from", "from must be the first day of a month as YYYY-MM-01");
  }
  const monthsText = sp.get("months");
  const months = monthsText === null ? MAINTENANCE_DEFAULT_HORIZON : Number(monthsText);
  if (!Number.isInteger(months) || months < 1 || months > 24 || (monthsText !== null && !/^\d{1,2}$/.test(monthsText))) {
    throw new ApiError(400, "invalid_months", "months must be a whole number from 1 to 24");
  }
  const market = sp.get("market");
  if (market !== null && !/^([A-Z]{2}|unknown)$/.test(market)) throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  const model = sp.get("model");
  if (model !== null && !(/^[a-z0-9]+(_[a-z0-9]+)*$/.test(model) && model.length <= 40)) {
    throw new ApiError(400, "invalid_model", "model must be a model's key or unknown");
  }
  const scope = parseScope(sp.get("scope"));
  if (scope === "invalid") throw new ApiError(400, "invalid_scope", "scope must be field or stock");
  return { fromMonth: from, months, market, model, scope };
}

/**
 * The device list's query: the page's (maintenanceParams) and &bucket (past_due, unknown, all or a month of the horizon as
 * YYYY-MM-01; required for the list, all when the file leaves it out), &view (exchanges or components; exchanges when
 * left out) and &limit (1 to 5000; 500 for the list, 5000 for the file when left out)
 */
export function maintenanceRowsParams(sp: URLSearchParams, o: { file?: boolean } = {}): { filter: MaintenanceFilter; bucket: string; view: MaintenanceView; limit: number } {
  const filter = maintenanceParams(sp);
  const bucket = sp.get("bucket") ?? (o.file ? "all" : null);
  if (bucketProblem(bucket)) throw new ApiError(400, "invalid_bucket", "bucket must be past_due, unknown, all or the first day of a month as YYYY-MM-01");
  const view = sp.has("view") ? parseView(sp.get("view")) : "exchanges";
  if (!view) throw new ApiError(400, "invalid_view", "view must be exchanges or components");
  const limitText = sp.get("limit");
  const limit = limitText === null ? (o.file ? MAINTENANCE_FILE_ROWS : MAINTENANCE_LIST_ROWS) : Number(limitText);
  if (!Number.isInteger(limit) || limit < 1 || limit > MAINTENANCE_FILE_ROWS || (limitText !== null && !/^\d{1,4}$/.test(limitText))) {
    throw new ApiError(400, "invalid_limit", "limit must be a whole number from 1 to 5000");
  }
  return { filter, bucket: bucket!, view, limit };
}
