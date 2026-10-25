/**
 * A fake eTrusted API (Trusted Shops) and the one HubSpot endpoint the reviews' contact match calls, on localhost, for
 * verify/reviews-mapping.mjs and verify/reviews-flow.mjs (addition 0008ze). Everything is invented.
 *
 *   POST /oauth/token        the client credentials grant: grant_type, client_id, client_secret and audience checked
 *                            against `clients`; { access_token, expires_in, token_type }
 *   GET  /channels           the channels (an array), with a valid bearer token
 *   GET  /reviews            channels (comma-separated), submittedAfter and submittedBefore (exclusive), count (default
 *                            50, at most 1000), after (a review id: the page after it), ignoreStatements (unless false,
 *                            star-only reviews are left out): newest first; { totalElements: 0 always, as the prod
 *                            discovery saw it, paging: { count, cursor: { before, after } }, items }
 *   POST /crm/v3/objects/contacts/search   HubSpot's search on email (lower case): at most two ids; with `daily` set,
 *                            the daily limit headers HubSpot sends
 *
 * Switches on state: fail429 (the next n API calls answer 429 with Retry-After 1), failReviewsAfter (after n more
 * successful /reviews answers, every one answers 503 until cleared), expiresIn (the next tokens' life in seconds).
 * state.requests records { method, path, query } (never a body: the token request holds the secret).
 */
import http from "node:http";
import { readFileSync } from "node:fs";

/** The fixture source: channels and reviews, times as "ago:<minutes>" turned into ISO times against nowMs. */
export function loadReviewsSource(nowMs = Date.now()) {
  const raw = JSON.parse(readFileSync(new URL("./fixtures/trustedshops/reviews-source.json", import.meta.url), "utf8"));
  const at = (v) => (typeof v === "string" && v.startsWith("ago:") ? new Date(nowMs - Number(v.slice(4)) * 60_000).toISOString() : v);
  return {
    channels: raw.channels,
    reviews: raw.reviews.map((r) => ({ ...r, submittedAt: at(r.submittedAt), updatedAt: at(r.updatedAt) })),
    contacts: raw.contacts,
  };
}

export async function startFakeETrusted({ clients, channels, reviews, contacts = {} }) {
  const state = {
    requests: [], mints: 0, tokens: new Map(), expiresIn: 300, fail429: 0, failReviewsAfter: null, reviewsAnswered: 0,
    channels, reviews, contacts, daily: null, searches: 0,
  };
  const json = (res, status, body, headers = {}) => {
    res.writeHead(status, { "content-type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };
  const server = http.createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      const url = new URL(req.url, "http://x");
      const query = Object.fromEntries(url.searchParams);
      state.requests.push({ method: req.method, path: url.pathname, query: url.pathname === "/oauth/token" ? {} : query });
      if (req.method === "POST" && url.pathname === "/oauth/token") {
        const f = Object.fromEntries(new URLSearchParams(data));
        if (f.grant_type !== "client_credentials" || f.audience !== "https://api.etrusted.com" || !clients[f.client_id] || clients[f.client_id] !== f.client_secret) {
          return json(res, 401, { error: "invalid_client" });
        }
        state.mints += 1;
        const token = `fixture-etrusted-token-${state.mints}`;
        state.tokens.set(token, f.client_id);
        return json(res, 200, { access_token: token, expires_in: state.expiresIn, token_type: "Bearer" });
      }
      if (req.method === "POST" && url.pathname === "/crm/v3/objects/contacts/search") {
        state.searches += 1;
        const body = JSON.parse(data || "{}");
        const value = String(body?.filterGroups?.[0]?.filters?.[0]?.value ?? "").toLowerCase();
        const ids = Object.entries(state.contacts).filter(([, c]) => String(c.email).toLowerCase() === value).map(([id]) => ({ id }));
        const headers = state.daily ? { "x-hubspot-ratelimit-daily": String(state.daily.limit), "x-hubspot-ratelimit-daily-remaining": String(state.daily.remaining) } : {};
        return json(res, 200, { total: ids.length, results: ids.slice(0, 2) }, headers);
      }
      const auth = /^Bearer (.+)$/.exec(req.headers.authorization ?? "")?.[1];
      if (!auth || !state.tokens.has(auth)) return json(res, 401, { error: "unauthorized" });
      if (state.fail429 > 0) {
        state.fail429 -= 1;
        return json(res, 429, { error: "too many requests" }, { "retry-after": "1" });
      }
      if (req.method === "GET" && url.pathname === "/channels") return json(res, 200, state.channels);
      if (req.method === "GET" && url.pathname === "/reviews") {
        if (state.failReviewsAfter !== null) {
          if (state.failReviewsAfter <= 0) return json(res, 503, { error: "unavailable" });
          state.failReviewsAfter -= 1;
        }
        state.reviewsAnswered += 1;
        const wanted = new Set(String(query.channels ?? "").split(",").filter(Boolean));
        const after = query.submittedAfter ? Date.parse(query.submittedAfter) : -Infinity;
        const before = query.submittedBefore ? Date.parse(query.submittedBefore) : Infinity;
        const count = Math.min(1000, Math.max(1, Number(query.count ?? 50)));
        let list = state.reviews
          .filter((r) => wanted.has(r.channelRef) && Date.parse(r.submittedAt) > after && Date.parse(r.submittedAt) < before)
          .filter((r) => query.ignoreStatements === "false" || !r.statement)
          .sort((a, b) => Date.parse(b.submittedAt) - Date.parse(a.submittedAt) || b.id.localeCompare(a.id));
        if (query.after) list = list.slice(list.findIndex((r) => r.id === query.after) + 1);
        const items = list.slice(0, count).map(({ statement: _s, ...r }) => r);
        return json(res, 200, { totalElements: 0, paging: { count: items.length, cursor: { before: items[0]?.id ?? null, after: items.at(-1)?.id ?? null } }, items });
      }
      return json(res, 404, { error: "not found" });
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, state, close: () => new Promise((r) => server.close(r)) };
}
