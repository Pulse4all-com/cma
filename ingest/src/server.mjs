/**
 * cma-ingest: the ingest service (README Architecture, Ingest API; DESIGN §2, §5, §6).
 *
 *   GET  /health          {"ok":true,"version":"<short sha>"}; no database
 *   POST /<adapter>/<key> a webhook from a connected system: the key gives the connection
 *                         (cma.ingest_connection), the adapter authenticates the request, the events
 *                         are recorded and committed, the objects are read back within the budget,
 *                         then 200
 *
 * Answers: unknown route, key or connection, or a connection of another adapter → 404, empty;
 * authentication failure → 401, empty, nothing written; a body over 1 MB → 413; a body that is not
 * JSON → 400; a database error before the events are committed, or a secret that cannot be read →
 * 500 (the source sends again). After the commit the answer is 200 whatever the read-back does:
 * what it could not finish waits for the sweeper.
 *
 * Environment (docs/ingest/deploy.sh sets these on Cloud Run):
 *   PORT                      8080
 *   INGEST_VERSION            the image's short sha, shown by /health
 *   INGEST_PROJECT            the Google Cloud project whose Secret Manager holds the secrets
 *   INGEST_PUBLIC_URLS        the service's public base URL(s), comma-separated: the URI a source signs
 *   INGEST_LOG_HEADER_NAMES   1 → log the header names (never the values) of every webhook (dev)
 *   INGEST_READBACK_BUDGET_MS 3000
 *   CMA_DB_*                  the database, as src/core/db.mjs describes
 */
import http from "node:http";
import { pathToFileURL } from "node:url";
import { ADAPTERS } from "./adapters/index.mjs";
import { lookupConnection, contextOf } from "./core/connection.mjs";
import { recordEvents } from "./core/events.mjs";
import { processEvents } from "./core/process.mjs";
import { readRawBody, BodyTooLarge } from "./core/rawbody.mjs";
import { Budget, readbackBudgetMs } from "./core/budget.mjs";
import { SecretUnavailable } from "./core/secrets.mjs";
import { dbErrorCode, closeDb } from "./core/db.mjs";
import { info, warn, error } from "./core/log.mjs";

const ROUTE = /^\/([a-z0-9_]+)\/([^/?#]+)\/?$/;

function send(res, status, body = null) {
  if (body === null) {
    res.writeHead(status, { "content-length": "0", "cache-control": "no-store" });
    res.end();
    return;
  }
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(text), "cache-control": "no-store" });
  res.end(text);
}

/** The URIs the source may have signed: each configured public base plus the path and query as received. */
export function requestUris(req) {
  const bases = (process.env.INGEST_PUBLIC_URLS ?? "").split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
  if (bases.length) return bases.map((b) => `${b}${req.url}`);
  return [`https://${req.headers.host}${req.url}`];
}

async function handleWebhook(req, res, adapter, key) {
  const started = Date.now();
  let body;
  try {
    body = await readRawBody(req);
  } catch (err) {
    send(res, err instanceof BodyTooLarge ? 413 : 400);
    return;
  }
  if (process.env.INGEST_LOG_HEADER_NAMES === "1") {
    info("webhook headers", { adapter: adapter.name, headerNames: Object.keys(req.headers).sort() });
  }

  let connection;
  try {
    connection = await lookupConnection(key);
  } catch (err) {
    error("connection lookup failed", { adapter: adapter.name, code: dbErrorCode(err) });
    send(res, 500);
    return;
  }
  if (!connection || connection.adapter !== adapter.name) {
    send(res, 404);
    return;
  }

  let auth;
  try {
    auth = await adapter.authenticate({ method: req.method, uris: requestUris(req), body, headers: req.headers, connection });
  } catch (err) {
    error("authentication unavailable", { connection: connection.connectionId, adapter: adapter.name,
      code: err instanceof SecretUnavailable ? "signing_secret_unavailable" : "authentication_error" });
    send(res, 500);
    return;
  }
  if (!auth.ok) {
    warn("authentication failed", { connection: connection.connectionId, adapter: adapter.name, code: auth.reason });
    send(res, 401);
    return;
  }

  let events;
  try {
    events = adapter.mapRequest(body, connection);
  } catch {
    warn("body not readable", { connection: connection.connectionId, adapter: adapter.name, code: "bad_body" });
    send(res, 400);
    return;
  }

  let recorded;
  try {
    recorded = events.length ? await recordEvents(contextOf(connection), connection.connectionId, events) : { rows: [], ignored: 0 };
  } catch (err) {
    error("events not recorded", { connection: connection.connectionId, adapter: adapter.name, events: events.length, code: dbErrorCode(err) });
    send(res, 500);
    return;
  }

  // Committed: from here on the answer is 200. The read-back runs within the budget.
  const due = recorded.rows.filter((r) => r.status === "received").map((r) => r.eventId);
  let processed = null;
  if (due.length) {
    try {
      processed = await processEvents(adapter, connection, due, new Budget(readbackBudgetMs()));
    } catch (err) {
      warn("read-back left to the sweeper", { connection: connection.connectionId, adapter: adapter.name, code: dbErrorCode(err) });
    }
  }
  const newCount = recorded.rows.filter((r) => r.isNew).length;
  info("webhook", {
    connection: connection.connectionId, adapter: adapter.name, events: events.length, new: newCount, ignored: recorded.ignored,
    processed: processed?.events ?? null, ms: Date.now() - started,
  });
  send(res, 200, { received: events.length, new: newCount });
}

export function createIngestServer({ adapters = ADAPTERS } = {}) {
  return http.createServer((req, res) => {
    const path = (req.url ?? "/").split("?")[0];
    if (req.method === "GET" && path === "/health") {
      send(res, 200, { ok: true, version: process.env.INGEST_VERSION ?? "dev" });
      return;
    }
    const m = ROUTE.exec(path);
    const adapter = m && Object.hasOwn(adapters, m[1]) ? adapters[m[1]] : null;
    if (req.method !== "POST" || !adapter) {
      req.resume();
      send(res, 404);
      return;
    }
    handleWebhook(req, res, adapter, m[2]).catch((err) => {
      error("request failed", { adapter: adapter.name, code: err?.code ?? "error" });
      if (!res.headersSent) send(res, 500);
    });
  });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  const port = Number(process.env.PORT ?? 8080);
  const server = createIngestServer();
  server.requestTimeout = 30_000;
  server.listen(port, () => info("listening", { port, version: process.env.INGEST_VERSION ?? "dev" }));
  const stop = () => {
    server.close(() => closeDb().finally(() => process.exit(0)));
    setTimeout(() => process.exit(0), 9_000).unref();
  };
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
}
