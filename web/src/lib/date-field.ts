/**
 * A date field that applies on Enter or blur only, never while typing (addition 0008zz for Reports → Flash's As of; since
 * CMA-099 also Configuration → Sources' reviews history start). A browser's date field reports a value as soon as its year's
 * digits make one: typing 2026 passes 0002, 0020 and 0202 first, so a field that acted on every change would act on those.
 * The rule: an empty field is no date (null); a complete date (a year of four digits, 1000 on, and a real calendar day)
 * within the field's range is that date; anything else applies nothing and, when the field is left, it shows the stored
 * value again. One copy of the rule, used by both fields.
 */

const DATE = /^\d{4}-\d{2}-\d{2}$/;

/** A YYYY-MM-DD that is a real date */
export function isDate(value: unknown): value is string {
  if (typeof value !== "string" || !DATE.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/**
 * What a date field applies: empty is null; a complete date (a year of four digits, 1000 on, a real calendar day) from
 * `min` (when given) to `max` (when given) is that date; anything else is false (apply nothing)
 */
export function appliedDate(value: string, min: string | null, max: string | null): string | null | false {
  if (value === "") return null;
  if (!isDate(value) || value < "1000-01-01") return false;
  if ((min !== null && value < min) || (max !== null && value > max)) return false;
  return value;
}

/**
 * Enter (`leaving` false) or blur (`leaving` true) on a date field holding `stored`: applies the field's value through
 * `apply` once, when it is complete, in range and differs from the stored one. A value that applies nothing leaves the
 * field as typed on Enter and shows the stored value again on blur. The blur that may follow Enter asks nothing more: the
 * mark lives on the input itself, so the element that replaces it (a key on the stored value) never meets an old mark.
 * `apply` may clear the mark (`delete input.dataset.applied`) when its write fails, so the same date can be asked again
 */
export function commitDate(input: HTMLInputElement, leaving: boolean, stored: string | null, min: string | null, max: string | null,
  apply: (next: string | null, input: HTMLInputElement) => void): void {
  const next = appliedDate(input.value, min, max);
  if (next === false) {
    if (leaving) input.value = stored ?? "";
    return;
  }
  if (next === stored || input.dataset.applied === String(next)) return;
  input.dataset.applied = String(next);
  apply(next, input);
}
