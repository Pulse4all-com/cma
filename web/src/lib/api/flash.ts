import { ApiError, dateParam } from "@/lib/api/respond";
import {
  FLASH_ADDRESS, FLASH_FILE_MAX_ROWS, FLASH_LIST_FILTERS, FLASH_OVERVIEWS, FLASH_PAGE_ROWS, listFilterValue, overviewOf, parseMarket, type FlashKey,
  type FlashOverviewDef,
} from "@/lib/flash";

/**
 * The query of the Flash routes (addition 0008zn): ?overview (one of the eleven keys), &market (a market code or
 * unknown), &asOf (a business date with a snapshot, YYYY-MM-DD; now when left out) and, for a flow overview, &from and
 * &to (the period's business dates). Anything the database would refuse for its form is a 400 here first; whether a
 * date has a snapshot, or lies before the tenant's today, the database decides (404 not_found, 400 invalid).
 */
export interface FlashQuery {
  overview: FlashKey | null;
  market: string | null;
  asOf: string | null;
  from: string | null;
  to: string | null;
}

export interface FlashRowsQuery extends FlashQuery {
  overview: FlashKey;
  filters: Record<string, string>;
  sort: string | null;
  descending: boolean;
  limit: number;
  offset: number;
}

function marketParam(sp: URLSearchParams): string | null {
  const market = sp.get(FLASH_ADDRESS.market);
  if (market === null || market === "") return null;
  const m = parseMarket(market);
  if (!m) throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  return m;
}

function optionalDate(sp: URLSearchParams, name: string): string | null {
  const v = sp.get(name);
  return v === null || v === "" ? null : dateParam(v, name);
}

/** The overview (required unless optional), the market, As of and the period */
export function flashParams(sp: URLSearchParams, o: { overviewRequired?: boolean } = {}): FlashQuery {
  const key = sp.get("overview");
  const def = key === null || key === "" ? null : overviewOf(key);
  if ((key !== null && key !== "" && !def) || (o.overviewRequired && !def)) {
    throw new ApiError(400, "invalid_overview", `overview must be one of ${FLASH_OVERVIEWS.map((x) => x.key).join(", ")}`);
  }
  const asOf = optionalDate(sp, FLASH_ADDRESS.asOf);
  const from = optionalDate(sp, FLASH_ADDRESS.from);
  const to = optionalDate(sp, FLASH_ADDRESS.to);
  if (from !== null && to !== null && from > to) throw new ApiError(400, "invalid_period", "from must be on or before to");
  if (to !== null && from === null) throw new ApiError(400, "invalid_period", "to needs from");
  return { overview: def?.key ?? null, market: marketParam(sp), asOf, from, to };
}

function wholeNumber(sp: URLSearchParams, name: string, fallback: number, min: number, max: number): number {
  const text = sp.get(name);
  if (text === null || text === "") return fallback;
  const n = Number(text);
  if (!/^\d{1,9}$/.test(text) || !Number.isInteger(n) || n < min || n > max) {
    throw new ApiError(400, `invalid_${name}`, `${name} must be a whole number from ${min} to ${max}`);
  }
  return n;
}

/**
 * The rows' query: flashParams with the overview required, &sort (a sort key of the overview; its default when left
 * out), &dir (asc or desc), &limit (1 to the file's maximum; 500 for a list, the file's maximum for a file when left
 * out), &offset (0 or more), &measure (one of the overview's count measures), a filter per dim as f_<dim> and the list's
 * own filters as f_<key> (FLASH_LIST_FILTERS, addition 0009f)
 */
export function flashRowsParams(sp: URLSearchParams, o: { file?: boolean; maxRows?: number } = {}): FlashRowsQuery {
  const q = flashParams(sp, { overviewRequired: true });
  const def = overviewOf(q.overview) as FlashOverviewDef;
  const sort = sp.get(FLASH_ADDRESS.sort);
  if (sort !== null && sort !== "" && !def.sorts.includes(sort)) {
    throw new ApiError(400, "invalid_sort", `sort must be one of ${def.sorts.join(", ")}`);
  }
  const dir = sp.get(FLASH_ADDRESS.dir);
  if (dir !== null && dir !== "" && dir !== "asc" && dir !== "desc") throw new ApiError(400, "invalid_dir", "dir must be asc or desc");
  const max = o.maxRows ?? FLASH_FILE_MAX_ROWS;
  const limit = wholeNumber(sp, "limit", o.file ? max : FLASH_PAGE_ROWS, 1, max);
  const offset = wholeNumber(sp, "offset", 0, 0, 100_000_000);
  const filters: Record<string, string> = {};
  // the list's own filters beside the dims (addition 0009f, FLASH_LIST_FILTERS as cma.flash_list_filters_of): the installed
  // base's serial (trimmed) and without_subscription_ref ("true" alone)
  const own = FLASH_LIST_FILTERS[def.key] ?? [];
  for (const [k, v] of sp.entries()) {
    if (!k.startsWith(FLASH_ADDRESS.filterPrefix)) continue;
    const dim = k.slice(FLASH_ADDRESS.filterPrefix.length);
    if (own.includes(dim)) {
      const value = listFilterValue(dim, v);
      if (value === null) throw new ApiError(400, "invalid_filter", dim === "without_subscription_ref" ? `f_${dim} is true` : `f_${dim} is 1 to 100 characters`);
      filters[dim] = value;
      continue;
    }
    if (!def.dims.includes(dim)) throw new ApiError(400, "invalid_filter", `filters are f_ and one of ${[...def.dims, ...own].join(", ")}`);
    if (v.length < 1 || v.length > 100) throw new ApiError(400, "invalid_filter", "a filter's value is 1 to 100 characters");
    filters[dim] = v;
  }
  // market wins over f_market, as on the page: the list, the file's name and its filters column then name one market
  if (q.market) filters.market = q.market;
  else if (filters.market !== undefined && !parseMarket(filters.market)) {
    throw new ApiError(400, "invalid_market", "f_market must be a market code or unknown");
  }
  const measure = sp.get(FLASH_ADDRESS.measure);
  if (measure !== null && measure !== "") {
    if (!def.countMeasures.includes(measure)) throw new ApiError(400, "invalid_measure", `measure must be one of ${def.countMeasures.join(", ")}`);
    filters.measure = measure;
  }
  const s = sort === null || sort === "" ? null : sort;
  const descending = dir === "desc" ? true : dir === "asc" ? false : s === null || s === def.sorts[0] ? def.defaultDescending : false;
  return { ...q, overview: def.key, filters, sort: s ?? (q.asOf ? null : def.sorts[0] ?? null), descending, limit, offset };
}

/** The snapshots' period: &from and &to, each optional (the database takes the 90 days to today when both are left out, at most 400) */
export function flashSnapshotsParams(sp: URLSearchParams): { from: string | null; to: string | null } {
  const from = optionalDate(sp, "from");
  const to = optionalDate(sp, "to");
  if (from !== null && to !== null && from > to) throw new ApiError(400, "invalid_period", "from must be on or before to");
  return { from, to };
}

/** Data quality's rows: &check (a check's key), &market, &limit (1 to 50,000; 500 when left out) and &offset */
export function dataQualityRowsParams(sp: URLSearchParams, o: { file?: boolean } = {}): { check: string; market: string | null; limit: number; offset: number } {
  const check = sp.get("check");
  if (!check || !/^[a-z][a-z0-9_]{0,59}$/.test(check)) throw new ApiError(400, "invalid_check", "check must be a data-quality check's key");
  return { check, market: marketParam(sp), limit: wholeNumber(sp, "limit", o.file ? FLASH_FILE_MAX_ROWS : FLASH_PAGE_ROWS, 1, FLASH_FILE_MAX_ROWS),
    offset: wholeNumber(sp, "offset", 0, 0, 100_000_000) };
}
