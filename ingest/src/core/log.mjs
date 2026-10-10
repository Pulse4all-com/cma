/**
 * Structured logging: one JSON line per entry on stdout, which Cloud Logging reads as a structured
 * entry (severity, message, and the other fields as jsonPayload).
 *
 * What may be logged (DESIGN §5): connection ids, adapter names, counts, durations, error codes and
 * header NAMES. Never payloads, ids of contacts or customers, phone numbers, emails, secrets or
 * header values. Callers pass fields explicitly; nothing here serialises a request or a payload.
 */
const LEVELS = new Set(["DEBUG", "INFO", "WARNING", "ERROR"]);
let sink = (line) => process.stdout.write(line + "\n");

/** Replaces the output (the verifiers capture log lines to prove what is and is not written). */
export function setLogSink(fn) {
  sink = fn;
}

export function log(severity, message, fields = {}) {
  const entry = { severity: LEVELS.has(severity) ? severity : "INFO", message, ...fields, time: new Date().toISOString() };
  sink(JSON.stringify(entry));
}

export const info = (message, fields) => log("INFO", message, fields);
export const warn = (message, fields) => log("WARNING", message, fields);
export const error = (message, fields) => log("ERROR", message, fields);
