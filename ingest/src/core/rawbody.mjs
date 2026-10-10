/**
 * The raw request body, as bytes, up to a limit (DESIGN §5: 1 MB). Signatures are computed over the
 * raw body, so it is read once, kept as a Buffer and parsed only after authentication.
 */
export const MAX_BODY = 1024 * 1024;

export class BodyTooLarge extends Error {
  constructor() {
    super("body too large");
    this.code = "body_too_large";
  }
}

export function readRawBody(req, limit = MAX_BODY) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers["content-length"] ?? 0);
    if (declared > limit) {
      req.resume();
      reject(new BodyTooLarge());
      return;
    }
    const parts = [];
    let size = 0;
    let done = false;
    req.on("data", (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > limit) {
        done = true;
        req.resume();
        reject(new BodyTooLarge());
        return;
      }
      parts.push(chunk);
    });
    req.on("end", () => { if (!done) { done = true; resolve(Buffer.concat(parts)); } });
    req.on("error", (err) => { if (!done) { done = true; reject(err); } });
  });
}
