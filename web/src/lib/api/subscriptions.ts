import { ApiError } from "@/lib/api/respond";
import type { Principal } from "@/lib/auth/identity";
import type { SubscriptionsFilter, SubscriptionsMeasure, SubscriptionsPageQuery, SubscriptionsRowsQuery, SubscriptionsSort } from "@/lib/data";
import { currentMonthIn, measureOf, parseSubscriptionsFilter, sortOf, SUBSCRIPTIONS_MEASURES, SUBSCRIPTIONS_SORTS } from "@/lib/subscriptions";

/** The current month in the caller's zone (the database checks the range again in the tenant's) */
function currentMonth(me: Principal): string {
  return currentMonthIn(me.timeZone);
}

/**
 * The filters of the Subscriptions routes (addition 0009zh): &market (a market code or unknown), &store (a subscriptions
 * connection's id), &proposition (a proposition's code or none), &interval (monthly, quarterly, yearly, other or unknown).
 * Anything out of form is a 400 here first; a well-formed value the tenant does not hold is the database's 400 (CMA04)
 */
function filterOf(sp: URLSearchParams, me: Principal): { filter: SubscriptionsFilter; from: string; to: string } {
  const { filter, from, to, problem } = parseSubscriptionsFilter((k) => sp.get(k), currentMonth(me));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "store") throw new ApiError(400, "invalid_store", "store must be a subscriptions connection's id");
  if (problem === "proposition") throw new ApiError(400, "invalid_proposition", "proposition must be a proposition's code or none");
  if (problem === "interval") throw new ApiError(400, "invalid_interval", "interval must be monthly, quarterly, yearly, other or unknown");
  if (problem === "from" || problem === "to" || problem === "range") {
    throw new ApiError(400, `invalid_${problem}`, "from and to must be months as YYYY-MM, from at most to, to at most this month, at most 60 months");
  }
  return { filter, from, to };
}

function listOf(sp: URLSearchParams): { measure: SubscriptionsMeasure; sort: SubscriptionsSort; descending: boolean } {
  const rawMeasure = sp.get("measure");
  const measure = rawMeasure === null ? "total" : measureOf(rawMeasure);
  if (measure === null) throw new ApiError(400, "invalid_measure", `measure must be one of ${SUBSCRIPTIONS_MEASURES.join(", ")}`);
  const rawSort = sp.get("sort");
  const sort = rawSort === null ? "monthly_amount" : sortOf(rawSort);
  if (sort === null) throw new ApiError(400, "invalid_sort", `sort must be one of ${SUBSCRIPTIONS_SORTS.join(", ")}`);
  const dir = sp.get("dir") ?? "desc";
  if (dir !== "asc" && dir !== "desc") throw new ApiError(400, "invalid_dir", "dir must be asc or desc");
  return { measure, sort, descending: dir === "desc" };
}

/** The page's query: the filters, &from and &to (YYYY-MM; the last twelve complete months and the current one when left out), and the list's &measure, &sort, &dir and &page */
export function subscriptionsPageParams(sp: URLSearchParams, me: Principal): SubscriptionsPageQuery {
  const { filter, from, to } = filterOf(sp, me);
  const raw = sp.get("page");
  if (raw !== null && !/^[1-9][0-9]{0,4}$/.test(raw)) throw new ApiError(400, "invalid_page", "page must be a whole number from 1");
  return { ...filter, from, to, ...listOf(sp), page: raw === null ? 1 : Number(raw) };
}

/** The list's query: the filters, &measure, &sort, &dir and &page (from 1; 50 a page); a file reads every row up to the tenant's flash.file_max_rows */
export function subscriptionsRowsParams(sp: URLSearchParams, me: Principal, opts: { file?: boolean } = {}): SubscriptionsRowsQuery {
  const { filter } = filterOf(sp, me);
  const raw = sp.get("page");
  if (raw !== null && (opts.file || !/^[1-9][0-9]{0,4}$/.test(raw))) throw new ApiError(400, "invalid_page", opts.file ? "a file takes no page" : "page must be a whole number from 1");
  return { ...filter, ...listOf(sp), page: raw === null ? 1 : Number(raw), file: opts.file === true };
}

/** The file's part: records (the list, the default) or months (the movements and rates by month) */
export function subscriptionsFilePart(sp: URLSearchParams): "records" | "months" {
  const part = sp.get("part") ?? "records";
  if (part !== "records" && part !== "months") throw new ApiError(400, "invalid_part", "part must be records or months");
  return part;
}
