import { ApiError } from "@/lib/api/respond";
import type { Principal } from "@/lib/auth/identity";
import type { PaymentsListState, PaymentsPageQuery, PaymentsRowsQuery, PaymentsSort, SubscriptionsFilter } from "@/lib/data";
import { listStateOf, PAYMENTS_LIST_STATES, PAYMENTS_SORTS, paymentsSortOf } from "@/lib/payments";
import { currentMonthIn, parseSubscriptionsFilter } from "@/lib/subscriptions";

/**
 * The filters of the Payments routes (addition 0009zw): Customers → Subscriptions' own, &market (a market code or
 * unknown), &store (a subscriptions connection's id), &proposition (a proposition's code or none), &interval (monthly,
 * quarterly, yearly, other or unknown), &from and &to. Anything out of form is a 400 here first; a well-formed value the
 * tenant does not hold is the database's 400 (CMA04)
 */
function filterOf(sp: URLSearchParams, me: Principal): { filter: SubscriptionsFilter; from: string; to: string } {
  const { filter, from, to, problem } = parseSubscriptionsFilter((k) => sp.get(k), currentMonthIn(me.timeZone));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "store") throw new ApiError(400, "invalid_store", "store must be a subscriptions connection's id");
  if (problem === "proposition") throw new ApiError(400, "invalid_proposition", "proposition must be a proposition's code or none");
  if (problem === "interval") throw new ApiError(400, "invalid_interval", "interval must be monthly, quarterly, yearly, other or unknown");
  if (problem === "from" || problem === "to" || problem === "range") {
    throw new ApiError(400, `invalid_${problem}`, "from and to must be months as YYYY-MM, from at most to, to at most this month, within the tenant's history");
  }
  return { filter, from, to };
}

function listOf(sp: URLSearchParams): { state: PaymentsListState; sort: PaymentsSort; descending: boolean } {
  const rawState = sp.get("state");
  const state = rawState === null ? "at_risk" : listStateOf(rawState);
  if (state === null) throw new ApiError(400, "invalid_state", `state must be one of ${PAYMENTS_LIST_STATES.join(", ")}`);
  const rawSort = sp.get("sort");
  const sort = rawSort === null ? "amount_at_risk" : paymentsSortOf(rawSort);
  if (sort === null) throw new ApiError(400, "invalid_sort", `sort must be one of ${PAYMENTS_SORTS.join(", ")}`);
  const dir = sp.get("dir") ?? "desc";
  if (dir !== "asc" && dir !== "desc") throw new ApiError(400, "invalid_dir", "dir must be asc or desc");
  return { state, sort, descending: dir === "desc" };
}

/** The page's query: the filters, &from and &to (YYYY-MM; the last twelve complete months and the current one when left out), and the list's &state, &sort, &dir and &page */
export function paymentsPageParams(sp: URLSearchParams, me: Principal): PaymentsPageQuery {
  const { filter, from, to } = filterOf(sp, me);
  const raw = sp.get("page");
  if (raw !== null && !/^[1-9][0-9]{0,4}$/.test(raw)) throw new ApiError(400, "invalid_page", "page must be a whole number from 1");
  return { ...filter, from, to, ...listOf(sp), page: raw === null ? 1 : Number(raw) };
}

/** The list's query: the filters, &state, &sort, &dir and &page (from 1; 50 a page); a file reads every row up to the tenant's flash.file_max_rows */
export function paymentsRowsParams(sp: URLSearchParams, me: Principal, opts: { file?: boolean } = {}): PaymentsRowsQuery {
  const { filter } = filterOf(sp, me);
  const raw = sp.get("page");
  if (raw !== null && (opts.file || !/^[1-9][0-9]{0,4}$/.test(raw))) throw new ApiError(400, "invalid_page", opts.file ? "a file takes no page" : "page must be a whole number from 1");
  return { ...filter, ...listOf(sp), page: raw === null ? 1 : Number(raw), file: opts.file === true };
}

/** The file's part: records (the list, the default) or months (the Failed rate by month) */
export function paymentsFilePart(sp: URLSearchParams): "records" | "months" {
  const part = sp.get("part") ?? "records";
  if (part !== "records" && part !== "months") throw new ApiError(400, "invalid_part", "part must be records or months");
  return part;
}
