import { ApiError } from "@/lib/api/respond";
import { ACTIVE_CURSOR, ACTIVE_GROUPINGS, ACTIVE_PAGE_SIZE, ACTIVE_SORTS, parseActiveFilter } from "@/lib/active";
import type { ActiveFilter, ActiveGrouping, ActiveRowsRequest, ActiveSort } from "@/lib/data";

/** The filter of the Active routes: &market (a market code or unknown), &segment (a segment's code or unknown), &channel (indirect, direct or unknown) */
function filterOf(sp: URLSearchParams): ActiveFilter {
  const { filter, problem } = parseActiveFilter(sp.get("market"), sp.get("segment"), sp.get("channel"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "segment") throw new ApiError(400, "invalid_segment", "segment must be a segment's code or unknown");
  if (problem === "channel") throw new ApiError(400, "invalid_channel", "channel must be indirect, direct or unknown");
  return filter;
}

/**
 * The query of the Active route (addition 0009l): ?fromMonth (the history's first month as YYYY-MM-01; as far back as the
 * tenant keeps when left out), &grouping=month|quarter (the customer cohorts; month when left out) and the filter.
 * Anything the database would refuse is a 400 here first.
 */
export function activeParams(sp: URLSearchParams): { fromMonth: string | null; grouping: ActiveGrouping; filter: ActiveFilter } {
  const fromMonth = sp.get("fromMonth");
  // a year from 1900 on: the database has no year 0, and an earlier month than any subscription asks nothing more
  if (fromMonth !== null && (!/^(19|2\d)\d{2}-(0[1-9]|1[0-2])-01$/.test(fromMonth) || Number.isNaN(Date.parse(fromMonth)))) {
    throw new ApiError(400, "invalid_from_month", "fromMonth must be the first day of a month, as YYYY-MM-01");
  }
  const grouping = (sp.get("grouping") ?? "month") as ActiveGrouping;
  if (!ACTIVE_GROUPINGS.includes(grouping)) throw new ApiError(400, "invalid_grouping", "grouping must be month or quarter");
  return { fromMonth, grouping, filter: filterOf(sp) };
}

/**
 * The query of the list's routes: the filter, &sort (a sort key of the list; monthly_amount when left out), &dir=asc|desc
 * (desc when left out), &after or &before (a page's next or prev cursor, never both: keyset paging, no offset; a cursor
 * is the CMA's own id of a customer of the list and nothing else, since the address is logged) and
 * &limit (1 to 200; 50 when left out). A file takes the filter and the sort alone: every row, up to the tenant's
 * flash.file_max_rows.
 */
export function activeRowsParams(sp: URLSearchParams, opts: { file?: boolean } = {}): ActiveRowsRequest {
  const sort = (sp.get("sort") ?? "monthly_amount") as ActiveSort;
  if (!ACTIVE_SORTS.includes(sort)) throw new ApiError(400, "invalid_sort", `sort must be one of ${ACTIVE_SORTS.join(", ")}`);
  const dir = sp.get("dir") ?? "desc";
  if (dir !== "asc" && dir !== "desc") throw new ApiError(400, "invalid_dir", "dir must be asc or desc");
  const whole = (name: string, fallback: number, min: number, max: number) => {
    const raw = sp.get(name);
    if (raw === null) return fallback;
    const n = Number(raw);
    if (!/^\d{1,6}$/.test(raw) || n < min || n > max) throw new ApiError(400, `invalid_${name}`, `${name} must be a whole number from ${min} to ${max}`);
    return n;
  };
  // a cursor is the CMA's own id of a customer, as the database wrote it (and checks it: one that names no customer of the
  // tenant's take is refused there); anything out of that form is a 400 here
  const cursor = (name: "after" | "before") => {
    const raw = sp.get(name);
    if (raw === null || raw === "") return null;
    if (opts.file) throw new ApiError(400, `invalid_${name}`, "a file takes no cursor");
    if (!ACTIVE_CURSOR.test(raw)) throw new ApiError(400, `invalid_${name}`, `${name} must be the next or prev of a page of this list`);
    return raw;
  };
  const after = cursor("after");
  const before = cursor("before");
  if (after !== null && before !== null) throw new ApiError(400, "invalid_cursor", "after and before do not go together");
  return {
    filter: filterOf(sp), sort, descending: dir === "desc", after, before,
    limit: opts.file ? ACTIVE_PAGE_SIZE : whole("limit", ACTIVE_PAGE_SIZE, 1, 200), file: opts.file === true,
  };
}
