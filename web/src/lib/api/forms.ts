import { ApiError, teamRangeParams } from "@/lib/api/respond";
import type { FormsFilter, FormsGroup, HoursRange } from "@/lib/data";
import { MAX_REPORT_DAYS, parseAnswerFilter, parseFormsFilter, parseFormsGroup } from "@/lib/reports";

/**
 * The query of the Forms routes (addition 0008p): ?from&to (at most 92 days), &market (a market code or
 * unknown), &category (a category code or none) and &form (a connection id ':' form id), each optional,
 * &group=day|week (day when left out) and, for the answers, &field and &value. Anything the database would
 * refuse is a 400 here first.
 */
export function formsParams(sp: URLSearchParams): {
  range: HoursRange; filter: FormsFilter; group: FormsGroup; field: string | null; value: string | null;
} {
  const { from, to } = teamRangeParams(sp, MAX_REPORT_DAYS);
  const { filter, problem } = parseFormsFilter(sp.get("market"), sp.get("category"), sp.get("form"));
  if (problem === "market") throw new ApiError(400, "invalid_market", "market must be a market code or unknown");
  if (problem === "category") throw new ApiError(400, "invalid_category", "category must be a category code or none");
  if (problem === "form") throw new ApiError(400, "invalid_form", "form must be a connection id and a form id");
  const group = sp.has("group") ? parseFormsGroup(sp.get("group")) : "day";
  if (!group) throw new ApiError(400, "invalid_group", "group must be day or week");
  const answer = parseAnswerFilter(sp.get("field"), sp.get("value"));
  if (answer.problem) throw new ApiError(400, "invalid_answer", "field must be a field name and value at most 200 characters");
  if (answer.value !== null && answer.field === null) throw new ApiError(400, "invalid_answer", "value needs a field");
  return { range: { from, to }, filter, group, field: answer.field, value: answer.value };
}
