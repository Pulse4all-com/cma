/**
 * A page address reduced to what may be stored (DESIGN §4.1, form_submission): the host and the
 * path, never the query string or the fragment, and the five UTM parameters of the query, each at
 * most 200 characters. Everything else in the query (click ids, emails some forms append, tokens)
 * is dropped. Pure: no database, no network.
 */
export const UTM_KEYS = ["source", "medium", "campaign", "term", "content"];

export function parsePage(url) {
  const out = { host: null, path: null, utm: {} };
  if (typeof url !== "string" || !url.trim() || url.length > 4000) return out;
  let u;
  try {
    u = new URL(url.trim());
  } catch {
    return out;
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") return out;
  const host = u.hostname.toLowerCase();
  out.host = /^[a-z0-9.-]{1,255}$/.test(host) ? host : null;
  out.path = (u.pathname || "/").slice(0, 1000);
  for (const k of UTM_KEYS) {
    const v = u.searchParams.get(`utm_${k}`);
    if (v !== null && v.trim()) out.utm[k] = v.trim().slice(0, 200);
  }
  return out;
}
