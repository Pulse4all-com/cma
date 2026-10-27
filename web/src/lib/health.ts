/**
 * System health (Configuration → System health, addition 0008r; full IT audit of 17 October 2026): the
 * states the page shows, derived here from counts, ages and codes, so a verifier proves them without a
 * browser or a database. Pure: no runtime imports.
 *
 * The page reads Postgres only. Vendor health is what the ingest jobs leave behind in cma.sync_run and
 * cma.ingest_event (cma.sources(), cma.system_health_runs(), cma.outbox_status()); nothing here pings a
 * vendor. The thresholds are tenant settings (health.heartbeat_fresh_seconds, health.heartbeat_late_seconds),
 * never code; the defaults below only cover a settings read that lacks them.
 *
 * Also here: the documents an admin may download, as a fixed allowlist of names. The route under
 * /api/v1/configuration/documents/<name> accepts a name only when it is on this list AND in the manifest
 * written at build; a separator, a dot-dot or any other character refuses it before the file system is asked.
 */

/** The sweep writes one link_calls run per tenant per minute: the ingest heartbeat */
export const HEARTBEAT_JOB = "link_calls";
export const SCHEDULER_JOB = "close_forgotten_workdays";

/** Defaults as 0008r seeds them; the tenant's settings win */
export const HEARTBEAT_FRESH_SECONDS_DEFAULT = 120;
export const HEARTBEAT_LATE_SECONDS_DEFAULT = 900;

/** A run considered stuck when still running after this many seconds (Cloud Run's job task timeout is 10 minutes) */
export const RUNNING_TOO_LONG_SECONDS = 15 * 60;

export type HeartbeatState = "fresh" | "late" | "silent" | "none";
export type ConnectionState = "ok" | "attention" | "failing" | "off";
export type JobState = "ok" | "failed" | "running" | "stuck" | "never";
export type ProbeState = "fast" | "slow" | "down";

/** One row of cma.system_health_runs(): per job and connection over the last 30 days */
export interface HealthRun {
  job: string;
  connectionId: string | null;
  lastStartedAt: string;
  lastFinishedAt: string | null;
  lastStatus: "running" | "succeeded" | "failed";
  lastError: string | null;
  lastCounts: Record<string, number>;
  lastSucceededAt: string | null;
  lastFailedAt: string | null;
  lastFailedError: string | null;
  runs24h: number;
  failed24h: number;
}

/** What the heartbeat and connection rules need from a source (a subset of SourceConnection) */
export interface HealthSource {
  id: string;
  isActive: boolean;
  events24h: number;
  eventsWaiting: number;
  eventsParked: number;
  lastEventAt: string | null;
}

export interface HeartbeatThresholds {
  freshSeconds: number;
  lateSeconds: number;
}

/** The two thresholds from the tenant's settings, the defaults where a key is missing or unreadable */
export function heartbeatThresholds(settings: { key: string; value: string }[]): HeartbeatThresholds {
  const read = (key: string, fallback: number): number => {
    const raw = settings.find((s) => s.key === key)?.value;
    const n = raw === undefined ? NaN : Number(raw);
    return Number.isInteger(n) && n > 0 ? n : fallback;
  };
  return {
    freshSeconds: read("health.heartbeat_fresh_seconds", HEARTBEAT_FRESH_SECONDS_DEFAULT),
    lateSeconds: read("health.heartbeat_late_seconds", HEARTBEAT_LATE_SECONDS_DEFAULT),
  };
}

/** Whole seconds from an ISO instant to now, never negative */
export function ageSeconds(instant: string | null, nowMs: number): number | null {
  if (!instant) return null;
  const t = Date.parse(instant);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.floor((nowMs - t) / 1000));
}

/** fresh below the first threshold, silent from the second, late in between, none without a run */
export function heartbeatState(age: number | null, thresholds: HeartbeatThresholds): HeartbeatState {
  if (age === null) return "none";
  if (age < thresholds.freshSeconds) return "fresh";
  if (age < thresholds.lateSeconds) return "late";
  return "silent";
}

/** The latest heartbeat run (the sweep's link_calls row) among the runs, or null */
export function heartbeatRun(runs: HealthRun[]): HealthRun | null {
  const mine = runs.filter((r) => r.job === HEARTBEAT_JOB);
  if (mine.length === 0) return null;
  return mine.reduce((a, b) => (Date.parse(b.lastStartedAt) > Date.parse(a.lastStartedAt) ? b : a));
}

/**
 * The state of one job's row: failed when its last run failed; stuck when it is still running past the
 * task timeout; running while it runs; ok otherwise. A job without a row in 30 days is never.
 */
export function jobState(run: HealthRun | null, nowMs: number): JobState {
  if (!run) return "never";
  if (run.lastStatus === "running") {
    const age = ageSeconds(run.lastStartedAt, nowMs) ?? 0;
    return age > RUNNING_TOO_LONG_SECONDS ? "stuck" : "running";
  }
  return run.lastStatus === "failed" ? "failed" : "ok";
}

/**
 * The state of a connection from what its jobs and events left behind. Off when switched off. Failing
 * when any of its jobs' last run failed, or a job has run and never succeeded in the window. Attention
 * when events are parked for review, when a job failed in the last 24 hours (and recovered), or when an
 * active connection that has had events heard nothing for a day. Ok otherwise. The states are derived,
 * never a live ping: "ok" means the last read-back succeeded and events keep arriving.
 */
export function connectionState(source: HealthSource, runs: HealthRun[], nowMs: number): ConnectionState {
  if (!source.isActive) return "off";
  const mine = runs.filter((r) => r.connectionId === source.id);
  if (mine.some((r) => jobState(r, nowMs) === "failed" || jobState(r, nowMs) === "stuck")) return "failing";
  if (mine.some((r) => r.lastSucceededAt === null && r.lastStatus !== "running")) return "failing";
  if (source.eventsParked > 0) return "attention";
  if (mine.some((r) => r.failed24h > 0)) return "attention";
  const lastEvent = ageSeconds(source.lastEventAt, nowMs);
  if (lastEvent !== null && lastEvent > 24 * 3600) return "attention";
  return "ok";
}

/** The database probe: one trivial query's round trip in milliseconds (200 ms is slow for a select 1) */
export function probeState(roundTripMs: number | null): ProbeState {
  if (roundTripMs === null) return "down";
  return roundTripMs > 200 ? "slow" : "fast";
}

/** Milliseconds a finished run took, null while it runs */
export function runDurationMs(run: HealthRun): number | null {
  if (!run.lastFinishedAt) return null;
  return Math.max(0, Date.parse(run.lastFinishedAt) - Date.parse(run.lastStartedAt));
}

/** Every job name the page lists, in the order shown; the scheduled ones first */
export const JOB_ORDER: readonly string[] = [
  "link_calls", "forms_poll", "email_poll", "reconcile", "close_forgotten_workdays", "refresh_follow_up", "subscriptions_check", "reviews_poll", "backfill", "assets_import",
];

/** The runs grouped per job, in JOB_ORDER then alphabetically for jobs the list does not know */
export function runsByJob(runs: HealthRun[]): { job: string; runs: HealthRun[] }[] {
  const jobs = new Map<string, HealthRun[]>();
  for (const r of runs) jobs.set(r.job, [...(jobs.get(r.job) ?? []), r]);
  const rank = (j: string) => { const i = JOB_ORDER.indexOf(j); return i === -1 ? JOB_ORDER.length : i; };
  return [...jobs.entries()]
    .sort((a, b) => rank(a[0]) - rank(b[0]) || a[0].localeCompare(b[0]))
    .map(([job, list]) => ({ job, runs: list.sort((a, b) => Date.parse(b.lastStartedAt) - Date.parse(a.lastStartedAt)) }));
}

// ---- Documents -------------------------------------------------------------------------------

/**
 * The documents an admin may download, by name. The build copies them from docs/ into the image's
 * documents directory and writes the manifest; a name missing from the manifest is "not in this build".
 */
export const DOCUMENT_ALLOWLIST: readonly string[] = [
  "REPORT.md", "PERFORMANCE.md", "READINESS.md", "UX_REVIEW.md", "FINDINGS.csv", "METHOD.md", "OPERATIONS.md", "PLAN_B.md",
];

export interface DocumentEntry {
  name: string;
  bytes: number;
  sha256: string;
}

export interface DocumentsManifest {
  /** The short SHA of the build that wrote it, or "dev" */
  version: string;
  writtenAt: string;
  documents: DocumentEntry[];
}

/** A plain file name: letters, digits, dot, underscore, dash; no separator, no dot-dot, on the allowlist */
export function isDocumentName(name: unknown): name is string {
  return typeof name === "string"
    && name.length > 0 && name.length <= 64
    && /^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(name)
    && !name.includes("..")
    && DOCUMENT_ALLOWLIST.includes(name);
}

/** The manifest's entry for a name, or null when the name is not allowed or not in this build */
export function documentEntry(manifest: DocumentsManifest | null, name: unknown): DocumentEntry | null {
  if (!manifest || !isDocumentName(name)) return null;
  return manifest.documents.find((d) => d.name === name) ?? null;
}

/** An external link the page may render: https only, no spaces or quotes, as the database setting takes it */
export function isHttpsUrl(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 500 && /^https:\/\/[^\s"'<>]+$/.test(value);
}

/** Markdown and CSV go out as downloads with a fixed type; nothing else is on the allowlist */
export function documentContentType(name: string): string {
  if (name.endsWith(".csv")) return "text/csv; charset=utf-8";
  return "text/markdown; charset=utf-8";
}

/** The manifest, checked shape by shape; anything else is no manifest */
export function parseManifest(raw: unknown): DocumentsManifest | null {
  if (!raw || typeof raw !== "object") return null;
  const m = raw as Record<string, unknown>;
  if (typeof m.version !== "string" || typeof m.writtenAt !== "string" || !Array.isArray(m.documents)) return null;
  const documents: DocumentEntry[] = [];
  for (const d of m.documents) {
    if (!d || typeof d !== "object") return null;
    const e = d as Record<string, unknown>;
    if (!isDocumentName(e.name) || typeof e.bytes !== "number" || typeof e.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(e.sha256)) return null;
    documents.push({ name: e.name, bytes: e.bytes, sha256: e.sha256 });
  }
  return { version: m.version, writtenAt: m.writtenAt, documents };
}
