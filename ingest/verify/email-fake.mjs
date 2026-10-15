/**
 * A fake HubSpot for the email verifiers (verify/email-mapping.mjs, verify/email-flow.mjs), on
 * localhost: the owners, the email engagements' search, associations and contacts' batch read, and
 * the conversations API (inboxes, channels, channel accounts, threads, one thread, its messages), from
 * verify/fixtures/hubspot/email-source.json. Pages of `page` results, so every listing pages. Every
 * request is kept (method, path, query, body) for the checks.
 *
 * Its rules follow HubSpot's where the verifiers depend on them: a thread listing sorted by
 * latestMessageTimestamp without latestMessageTimestampAfter is refused (400), the listing then
 * answers ascending; archived threads are listed only with archived=true and read by id only with it;
 * a thread's ticket comes only with association=TICKET; a contact's batch read answers only the
 * properties asked for.
 */
import http from "node:http";
import { readFileSync } from "node:fs";

/** The fixture with every 'ago:<minutes>' turned into an ISO time before nowMs. */
export function loadSource(nowMs) {
  const raw = JSON.parse(readFileSync(new URL("./fixtures/hubspot/email-source.json", import.meta.url), "utf8"));
  const walk = (v) => {
    if (typeof v === "string" && /^ago:\d+$/.test(v)) return new Date(nowMs - Number(v.slice(4)) * 60_000).toISOString();
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x)]));
    return v;
  };
  return walk(raw);
}

const ms = (v) => (v ? Date.parse(v) : null);

export async function startFakeHubSpot(source, { page = 2 } = {}) {
  const state = {
    source,
    requests: [],
    gone: new Set(),          // thread ids the source no longer has (404, also among archived ones)
    archived: new Set(),      // thread ids in the trash
    failSearch: null,         // { status, skip } once: the email search after `skip` more answers it
    failConversations: null,  // { status } once: the next conversations call answers it
  };
  const json = (res, status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  const paged = (list, after) => {
    const offset = Number(after ?? 0);
    return { results: list.slice(offset, offset + page), ...(offset + page < list.length ? { paging: { next: { after: String(offset + page) } } } : {}) };
  };
  const thread = (id, withTicket) => {
    const t = { id, ...source.threads[id], archived: state.archived.has(id) };
    if (!withTicket) delete t.threadAssociations;
    return t;
  };
  const server = http.createServer((req, res) => {
    let data = "";
    req.on("data", (c) => { data += c; });
    req.on("end", () => {
      const url = new URL(req.url, "http://x");
      const body = data ? JSON.parse(data) : null;
      const query = {};
      for (const [k, v] of url.searchParams) query[k] = query[k] === undefined ? v : [].concat(query[k], v);
      state.requests.push({ method: req.method, path: url.pathname, query, body });
      let m;
      if (url.pathname === "/crm/v3/owners") {
        return json(res, 200, paged(query.archived === "true" ? source.owners.archived : source.owners.active, query.after));
      }
      if (url.pathname === "/crm/v3/objects/emails/search") {
        if (state.failSearch && (state.failSearch.skip ?? 0) > 0) {
          state.failSearch.skip -= 1;
        } else if (state.failSearch) {
          const f = state.failSearch;
          state.failSearch = null;
          return json(res, f.status, { status: "error" });
        }
        const [gte, lte] = body.filterGroups[0].filters;
        const prop = gte.propertyName;
        const all = Object.entries(source.engagements)
          .filter(([, o]) => o[prop] && ms(o[prop]) >= Number(gte.value) && (!lte || ms(o[prop]) <= Number(lte.value)))
          .sort((a, b) => ms(a[1][prop]) - ms(b[1][prop]) || a[0].localeCompare(b[0]));
        const p = paged(all, body.after);
        p.results = p.results.map(([id, o]) => ({ id, createdAt: o.hs_createdate, updatedAt: o.hs_lastmodifieddate, archived: false,
          properties: Object.fromEntries(body.properties.filter((x) => o[x] !== undefined).map((x) => [x, o[x]])) }));
        return json(res, 200, { total: all.length, ...p });
      }
      if ((m = /^\/crm\/v4\/associations\/emails\/(contacts|deals|tickets)\/batch\/read$/.exec(url.pathname))) {
        const map = source.emailAssociations[m[1]] ?? {};
        return json(res, 200, { status: "COMPLETE", results: body.inputs.filter((i) => map[i.id]?.length)
          .map((i) => ({ from: { id: String(i.id) }, to: map[i.id].map((t) => ({ toObjectId: Number(t), associationTypes: [] })) })) });
      }
      if (url.pathname === "/crm/v3/objects/contacts/batch/read") {
        const results = body.inputs.filter((i) => source.contacts[i.id]).map((i) => {
          const o = source.contacts[i.id];
          return { id: String(i.id), updatedAt: o.lastmodifieddate, archived: false,
            properties: Object.fromEntries(body.properties.filter((x) => o[x] !== undefined).map((x) => [x, o[x]])) };
        });
        return json(res, results.length === body.inputs.length ? 200 : 207, { status: "COMPLETE", results });
      }
      if (url.pathname === "/crm/v3/properties/emails") return json(res, 200, { results: source.emailProperties ?? [] });
      if (url.pathname === "/conversations/v3/conversations/actors/batch/read") {
        const TYPES = { A: "AGENT", V: "VISITOR", E: "EMAIL", S: "SYSTEM", B: "BOT", I: "INTEGRATOR", L: "LLM" };
        const results = body.inputs.map((id) => [id, TYPES[/^([A-Z])-/.exec(id)?.[1]]]).filter(([, t]) => t)
          .map(([id, type]) => ({ id, type, name: "Invented Customer", ...(type === "EMAIL" ? { email: id.slice(2) } : {}) }));
        return json(res, results.length === body.inputs.length ? 200 : 207, { status: "COMPLETE", results });
      }
      if (url.pathname.startsWith("/conversations/v3/conversations/")) {
        if (state.failConversations) {
          const f = state.failConversations;
          state.failConversations = null;
          return json(res, f.status, { status: "error" });
        }
        const rest = url.pathname.slice("/conversations/v3/conversations/".length);
        if (rest === "inboxes") return json(res, 200, { total: source.inboxes.length, ...paged(source.inboxes, query.after) });
        if (rest === "channels") return json(res, 200, { total: source.channels.length, ...paged(source.channels, query.after) });
        if (rest === "channel-accounts") return json(res, 200, { total: source.channelAccounts.length, ...paged(source.channelAccounts, query.after) });
        if (rest === "threads") {
          if (query.sort === "latestMessageTimestamp" && !query.latestMessageTimestampAfter) return json(res, 400, { status: "error", message: "latestMessageTimestampAfter required" });
          const wantArchived = query.archived === "true";
          let ids = Object.keys(source.threads).filter((id) => !state.gone.has(id) && state.archived.has(id) === wantArchived);
          if (query.threadStatus) ids = ids.filter((id) => source.threads[id].status === query.threadStatus);
          if (query.latestMessageTimestampAfter) ids = ids.filter((id) => ms(source.threads[id].latestMessageTimestamp) >= ms(query.latestMessageTimestampAfter));
          ids.sort((a, b) => (query.sort === "latestMessageTimestamp"
            ? ms(source.threads[a].latestMessageTimestamp) - ms(source.threads[b].latestMessageTimestamp) || a.localeCompare(b) : a.localeCompare(b)));
          return json(res, 200, paged(ids.map((id) => thread(id, query.association === "TICKET")), query.after));
        }
        if ((m = /^threads\/(\d+)$/.exec(rest))) {
          const id = m[1];
          if (!source.threads[id] || state.gone.has(id) || state.archived.has(id) !== (query.archived === "true")) return json(res, 404, { status: "error" });
          return json(res, 200, thread(id, query.association === "TICKET"));
        }
        if ((m = /^threads\/(\d+)\/messages$/.exec(rest))) {
          const id = m[1];
          if (!source.threads[id] || state.gone.has(id)) return json(res, 404, { status: "error" });
          return json(res, 200, paged(source.messages[id] ?? [], query.after));
        }
      }
      json(res, 404, { status: "error" });
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${server.address().port}`, state, close: () => new Promise((r) => server.close(r)) };
}
