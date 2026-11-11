/**
 * Intl formatters built once per locale and options, then reused (the Live board's speed review, 10 November 2026):
 * building an Intl.NumberFormat or Intl.DateTimeFormat costs far more than formatting with one, and a board renders a
 * few thousand figures at volume, on the server and again on every poll. The answers are the same as a new formatter's.
 * No runtime imports, so the pure verifiers load it under Node's type stripping.
 */
const numberFormats = new Map<string, Intl.NumberFormat>();
const dateTimeFormats = new Map<string, Intl.DateTimeFormat>();

/** new Intl.NumberFormat(locale, options), cached */
export function numberFormat(locale: string, options?: Intl.NumberFormatOptions): Intl.NumberFormat {
  const key = `${locale}|${options ? JSON.stringify(options) : ""}`;
  let f = numberFormats.get(key);
  if (!f) {
    f = new Intl.NumberFormat(locale, options);
    numberFormats.set(key, f);
  }
  return f;
}

/** new Intl.DateTimeFormat(locale, options), cached */
export function dateTimeFormat(locale: string, options?: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const key = `${locale}|${options ? JSON.stringify(options) : ""}`;
  let f = dateTimeFormats.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat(locale, options);
    dateTimeFormats.set(key, f);
  }
  return f;
}
