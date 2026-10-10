/**
 * Secrets by name, with a 5-minute cache (DESIGN §5). The database holds only secret NAMES; the
 * values live in Secret Manager in the service's own project, readable by the service account
 * through a per-secret accessor grant.
 *
 * Providers:
 *   Secret Manager (Cloud Run)  the REST API with the metadata server's token; the project from
 *                               INGEST_PROJECT (set by docs/ingest/deploy.sh)
 *   a local directory           INGEST_SECRETS_DIR=<dir>: the value is the file <dir>/<name>, for
 *                               the flow verifier and local runs; never set on Cloud Run
 *
 * A value is never logged, never put in an error message and never returned to a caller other than
 * the code that signs, verifies or authenticates with it.
 */
import { readFile } from "node:fs/promises";
import path from "node:path";

const TTL_MS = 5 * 60_000;
const NAME = /^[A-Za-z0-9_-]{1,255}$/;
const cache = new Map();

export class SecretUnavailable extends Error {
  constructor(name, reason) {
    super(`secret ${name} unavailable (${reason})`);
    this.name = "SecretUnavailable";
    this.code = "secret_unavailable";
  }
}

async function metadataToken() {
  const res = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", {
    headers: { "Metadata-Flavor": "Google" }, signal: AbortSignal.timeout(2000),
  });
  if (!res.ok) throw new Error(`metadata ${res.status}`);
  return (await res.json()).access_token;
}

async function fromSecretManager(name) {
  const project = process.env.INGEST_PROJECT;
  if (!project) throw new SecretUnavailable(name, "INGEST_PROJECT not set");
  const token = await metadataToken();
  const url = `https://secretmanager.googleapis.com/v1/projects/${encodeURIComponent(project)}/secrets/${name}/versions/latest:access`;
  const res = await fetch(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(3000) });
  if (res.status === 404 || res.status === 403) throw new SecretUnavailable(name, `secret manager ${res.status}`);
  if (!res.ok) throw new SecretUnavailable(name, `secret manager ${res.status}`);
  const body = await res.json();
  return Buffer.from(body.payload?.data ?? "", "base64").toString("utf8");
}

async function fromDirectory(dir, name) {
  try {
    return (await readFile(path.join(dir, name), "utf8")).replace(/\r?\n$/, "");
  } catch {
    throw new SecretUnavailable(name, "not in INGEST_SECRETS_DIR");
  }
}

/** The current value of a named secret; SecretUnavailable when the name is missing, invalid or unreadable. */
export async function getSecret(name) {
  if (!name || !NAME.test(name)) throw new SecretUnavailable(String(name ?? ""), "no valid name");
  const hit = cache.get(name);
  if (hit && hit.until > Date.now()) return hit.value;
  let value;
  try {
    value = process.env.INGEST_SECRETS_DIR ? await fromDirectory(process.env.INGEST_SECRETS_DIR, name) : await fromSecretManager(name);
  } catch (err) {
    if (err instanceof SecretUnavailable) throw err;
    throw new SecretUnavailable(name, "unreachable");
  }
  if (!value) throw new SecretUnavailable(name, "empty");
  cache.set(name, { value, until: Date.now() + TTL_MS });
  return value;
}

/** Drops the cache (the verifiers rotate secrets between cases). */
export function clearSecretCache() {
  cache.clear();
}
