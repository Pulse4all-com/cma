import { ApiError } from "@/lib/api/respond";
import type { FleetFilter, FleetPageQuery, FleetRowsQuery } from "@/lib/data";
import { FLEET_TILES } from "@/lib/fleet-management";

/**
 * The query of Assets → Fleet management's routes (addition 0009t): &market (a market code or unknown) and &model (a
 * model's key or unknown), as Installed base's and Maintenance's; anything the database would refuse for its form is a 400
 * here first. No tenant parameter: the tenant is the caller's
 */
export function fleetParams(sp: URLSearchParams): FleetFilter {
  const market = sp.get("market");
  if (market !== null && !/^([A-Z]{2}|unknown)$/.test(market)) throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  const model = sp.get("model");
  if (model !== null && !(/^[a-z0-9]+(_[a-z0-9]+)*$/.test(model) && model.length <= 40)) {
    throw new ApiError(400, "invalid_model", "model must be a model's key or unknown");
  }
  return { market, model };
}

/**
 * The page's query (addition 0009v): the filters, &state (a tile: in_field, past_due, monitored, ready, needs_attention,
 * no_connection or not_monitored) and &area (a postcode area's id)
 */
export function fleetPageParams(sp: URLSearchParams): FleetPageQuery {
  const filter = fleetParams(sp);
  const state = sp.get("state");
  if (state !== null && !(FLEET_TILES as readonly string[]).includes(state)) {
    throw new ApiError(400, "invalid_state", `state must be one of ${FLEET_TILES.join(", ")}`);
  }
  const area = sp.get("area");
  if (area !== null && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(area)) throw new ApiError(400, "invalid_area", "area must be a postcode area's id");
  return { ...filter, state, areaId: area };
}

/**
 * The list's query: the page's (the filters, &state, &area), &attention=1 (the devices that need attention only) and &page
 * (from 1; 50 a page)
 */
export function fleetRowsParams(sp: URLSearchParams): FleetRowsQuery {
  const { state, areaId: area, ...filter } = fleetPageParams(sp);
  const attention = sp.get("attention");
  if (attention !== null && attention !== "1" && attention !== "0") throw new ApiError(400, "invalid_attention", "attention must be 1 or 0");
  const pageText = sp.get("page");
  if (pageText !== null && !/^[1-9][0-9]{0,4}$/.test(pageText)) throw new ApiError(400, "invalid_page", "page must be a whole number from 1");
  return { ...filter, state, areaId: area, attentionOnly: attention === "1", page: pageText === null ? 1 : Number(pageText) };
}
