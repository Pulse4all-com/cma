/**
 * The email classification rules applied in memory (addition 0008m, brief B17b). The database is the
 * definition: cma.email_words_match (a value matches when it contains any of the words and none of
 * the exclude words, case-insensitive; a null or empty value matches nothing) and
 * cma.email_category_of (the first active rule by its order whose words the value of its kind
 * matches). The rules arrive from cma.connection_config already in that order and with their words
 * stored lower case and trimmed (cma.email_words). verify/email-mapping.mjs and verify/email-flow.mjs
 * run the same fixtures (verify/fixtures/hubspot/email-rules.json) through this code and through the
 * database function.
 *
 * The values matched (a sender's domain, a subject) exist here only, for the length of one call: they
 * are never returned, stored or logged; only the category code leaves.
 */

/** The words logic of cma.email_words_match. */
export function wordsMatch(value, words, exclude) {
  if (typeof value !== "string" || value === "") return false;
  const v = value.toLowerCase();
  return (words ?? []).some((w) => v.includes(w)) && !(exclude ?? []).some((w) => v.includes(w));
}

/** The active rules of a connection's configuration, in their order: [{ appliesTo, words, excludeWords, category }]. */
export function activeRules(config) {
  return (config?.emailRules ?? [])
    .filter((r) => r?.status === "active" && (r.appliesTo === "sender_domain" || r.appliesTo === "subject") && Array.isArray(r.words))
    .map((r) => ({ appliesTo: r.appliesTo, words: r.words, excludeWords: Array.isArray(r.excludeWords) ? r.excludeWords : [], category: r.category }));
}

/** Which values the rules need: { subject, senderDomain } (a value is asked from the source only when a rule needs it). */
export function ruleNeeds(rules) {
  return { subject: rules.some((r) => r.appliesTo === "subject"), senderDomain: rules.some((r) => r.appliesTo === "sender_domain") };
}

/** The category of the first rule whose words the value of its kind matches, or null. values: { subject, senderDomain }. */
export function classify(values, rules) {
  for (const r of rules ?? []) {
    const v = r.appliesTo === "subject" ? values?.subject : values?.senderDomain;
    if (wordsMatch(v, r.words, r.excludeWords)) return r.category;
  }
  return null;
}

/** The domain of an email address, lower case, or null. The address itself is not kept. */
export function domainOf(address) {
  if (typeof address !== "string") return null;
  const at = address.lastIndexOf("@");
  if (at < 1) return null;
  const d = address.slice(at + 1).trim().toLowerCase().replace(/[>\s]+$/, "");
  return /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(d) ? d : null;
}
