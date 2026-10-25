/**
 * The eTrusted reads (addition 0008zd): the channel list and the reviews of one channel in a window of submission
 * times, page by page.
 *
 *   channels  GET /channels: every channel of the account (id chl-…, name, locale)
 *   reviews   GET /reviews?channels=<id>&submittedAfter=<ISO>&submittedBefore=<ISO>&count=<n>[&after=<review id>]
 *             [&ignoreStatements=false]: cursor paging by review id (the answer's paging cursor after, else the last
 *             item's id) until a page holds fewer than asked. The answer's totalElements is never read: the prod
 *             discovery of 25 October 2026 saw 0 next to 10 items. ignoreStatements=false asks for the star-only
 *             reviews (statements) too, which the API leaves out otherwise (connection setting
 *             etrusted_include_statements, default true; to confirm on the live account)
 *
 * The parameter names follow the prod discovery and the developer reference as far as it could be read on
 * 25 October 2026; the PR and docs/open-decisions.md list them to confirm on the live account.
 */
import { etrustedClient, reviewSettings } from "./client.mjs";

export const PAGE_SIZE = 100;
const MAX_PAGES = 1000;

/** The API of a connection with its settings (cma.connection_config). */
export function clientFor(connection, settings, budget) {
  const api = etrustedClient(connection, settings, budget);
  const includeStatements = reviewSettings(settings).includeStatements;
  return {
    /** The account's channels as the API answers them (an array, or { items }). */
    async channels() {
      const r = await api.get("/channels");
      return Array.isArray(r) ? r : Array.isArray(r?.items) ? r.items : [];
    },
    /**
     * The reviews of one channel submitted after afterMs and before beforeMs (ms; either may be null), page by page:
     * yields each page's items.
     */
    async *reviews(channelId, afterMs, beforeMs) {
      let cursor = null;
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const q = new URLSearchParams({ channels: channelId, count: String(PAGE_SIZE) });
        if (Number.isFinite(afterMs)) q.set("submittedAfter", new Date(afterMs).toISOString());
        if (Number.isFinite(beforeMs)) q.set("submittedBefore", new Date(beforeMs).toISOString());
        if (cursor) q.set("after", cursor);
        if (includeStatements) q.set("ignoreStatements", "false");
        const r = await api.get(`/reviews?${q.toString()}`);
        const items = Array.isArray(r?.items) ? r.items : [];
        if (items.length) yield items;
        const next = r?.paging?.cursor?.after ?? r?.paging?.after ?? (typeof items.at(-1)?.id === "string" ? items.at(-1).id : null);
        if (items.length < PAGE_SIZE || !next || next === cursor) return;
        cursor = next;
      }
    },
  };
}
