/**
 * Reading one object from Cloud Storage into memory (the legacy call import, addition 0008zg): the JSON API's media
 * download with the metadata server's token, as the job's service account, which holds storage.objectViewer on the
 * import bucket only (docs/ingest/deploy.sh). The object never touches the disk; the caller drops the bytes once
 * parsed. Errors carry a code only, never a body: object_not_found (404), object_forbidden (403), object_too_large,
 * timeout, unreachable, http_<status>. No redirect is followed.
 *
 *   INGEST_STORAGE_API_BASE   the API's address (default https://storage.googleapis.com); the verifiers point it at
 *                             a fake on the local machine. Never set on Cloud Run
 */
import { checkedBase, SourceError } from "./http.mjs";

export const MAX_OBJECT_BYTES = 20 * 1024 * 1024;
const BUCKET = /^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$/;

/** gs://<bucket>/<object> → { bucket, object }, or null when it is not one. */
export function parseGsUri(uri) {
  const m = /^gs:\/\/([^/]+)\/(.+)$/.exec(typeof uri === "string" ? uri.trim() : "");
  if (!m || !BUCKET.test(m[1]) || m[2].length > 1024 || [...m[2]].some((ch) => ch.charCodeAt(0) < 32 || ch.charCodeAt(0) === 127)) return null;
  return { bucket: m[1], object: m[2] };
}

async function metadataToken() {
  try {
    const res = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", {
      headers: { "Metadata-Flavor": "Google" }, signal: AbortSignal.timeout(2000),
    });
    if (!res.ok) throw new SourceError("token_unavailable");
    return (await res.json()).access_token;
  } catch (err) {
    throw err instanceof SourceError ? err : new SourceError("token_unavailable");
  }
}

/** The object's bytes (a Buffer), at most maxBytes; token: a function answering an access token (the metadata server's). */
export async function readObject({ bucket, object }, { token = metadataToken, maxBytes = MAX_OBJECT_BYTES, timeoutMs = 60_000 } = {}) {
  const base = checkedBase(process.env.INGEST_STORAGE_API_BASE ?? "https://storage.googleapis.com");
  const url = `${base}/storage/v1/b/${encodeURIComponent(bucket)}/o/${encodeURIComponent(object)}?alt=media`;
  let res;
  try {
    res = await fetch(url, { headers: { authorization: `Bearer ${await token()}` }, signal: AbortSignal.timeout(timeoutMs), redirect: "manual" });
  } catch (err) {
    if (err instanceof SourceError) throw err;
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => undefined);
    if (res.status === 404) throw new SourceError("object_not_found", 404);
    if (res.status === 403) throw new SourceError("object_forbidden", 403);
    throw new SourceError(`http_${res.status}`, res.status);
  }
  const parts = [];
  let size = 0;
  try {
    for await (const chunk of res.body ?? []) {
      size += chunk.byteLength;
      if (size > maxBytes) throw new SourceError("object_too_large");
      parts.push(chunk);
    }
  } catch (err) {
    if (err instanceof SourceError) throw err;
    if (err?.name === "TimeoutError" || err?.name === "AbortError") throw new SourceError("timeout");
    throw new SourceError("unreachable");
  }
  return Buffer.concat(parts);
}
