/**
 * The CMA's use of HubSpot's API (backlog CMA-069, 18 October 2026). On 18 October 2026 the prod app
 * made 173,444 calls in 24 hours, 17% of the portal's daily limit, which every app of the portal shares
 * (HubSpot, API usage guidelines: the burst limit is per app, the daily limit per account), almost all
 * of it polling. Pure: no I/O.
 *
 *   endpoints   every request counted per endpoint template: the method and the path with each id
 *               replaced by {id} (a segment holding a digit, apart from a version such as v3 or
 *               2026-09), never a query value, so a log line holds no id
 *   daily limit X-HubSpot-RateLimit-Daily and X-HubSpot-RateLimit-Daily-Remaining. HubSpot's usage
 *               guidelines document both and leave them out of OAuth-authorized requests, which have no
 *               daily limit; the CMA's app is a project app with static auth and private distribution,
 *               so it should receive them, which only a live response proves: the run logs say
 *               daily not_received when none came. HubSpot's published specs declare no response headers
 *   settings    the connection's settings (cma.set_connection_settings; a number or its digits as text,
 *               a boolean or true or false as text), each within its range or its default, every
 *               setting out of range named in one log line per run:
 *                 forms_poll_interval_minutes   1 to 1440, default 5: the forms that do not count in
 *                                               Intake (polled only) are read every so many minutes
 *                 email_open_check_minutes      1 to 1440, default 15: the open check of the email poll
 *                 api_daily_floor_pct           1 to 90, default 25: backfill and reconcile pause below it
 *                 forms_poll_probe              default false: one contacts search before the counted forms
 *   cadence     the forms poll reads every counted form each minute (speed to lead, Intake) and the
 *               polled-only forms on a cadence, staggered by form: their slots follow the forms' order, so
 *               each minute of an interval holds an even share; a run reads the slots of every minute
 *               since the previous run, so a skipped minute (an execution still holding the job's lock)
 *               only delays its share, and a gap of a whole interval reads every form. The cursor of each
 *               form reads every submission newer than the last one read, whatever the gap, so the cadence
 *               delays a submission and never loses one
 */
export const DAILY_HEADER = "x-hubspot-ratelimit-daily";
export const DAILY_REMAINING_HEADER = "x-hubspot-ratelimit-daily-remaining";

const VERSION = /^(v\d+|\d{4}-\d{2}(-[a-z]+)?)$/;

/** POST /crm/v3/objects/contacts/search → itself; GET /form-integrations/v1/submissions/forms/<guid>?limit=50 → …/forms/{id} */
export function endpointOf(method, path) {
  const segments = String(path).split("?")[0].split("/").map((s) => (/\d/.test(s) && !VERSION.test(s) ? "{id}" : s));
  return `${String(method).toUpperCase()} ${segments.join("/")}`;
}

/** The daily limit a response states, { limit, remaining }, or null when it states none (or no whole numbers) */
export function dailyOf(headers) {
  const read = (name) => {
    const v = headers?.get?.(name);
    return typeof v === "string" && /^\s*\d+\s*$/.test(v) ? Number(v) : null;
  };
  const limit = read(DAILY_HEADER);
  const remaining = read(DAILY_REMAINING_HEADER);
  return limit !== null && limit > 0 && remaining !== null ? { limit, remaining } : null;
}

export const SETTINGS = {
  forms_poll_interval_minutes: { default: 5, min: 1, max: 1440 },
  email_open_check_minutes: { default: 15, min: 1, max: 1440 },
  api_daily_floor_pct: { default: 25, min: 1, max: 90 },
  forms_poll_probe: { default: false },
};

function whole(settings, name, fallbacks) {
  const spec = SETTINGS[name];
  const v = settings[name];
  if (v === undefined || v === null || v === "") return spec.default;
  const n = typeof v === "number" ? v : typeof v === "string" && /^\s*\d+\s*$/.test(v) ? Number(v) : Number.NaN;
  if (Number.isInteger(n) && n >= spec.min && n <= spec.max) return n;
  fallbacks.push(name);
  return spec.default;
}

function flag(settings, name, fallbacks) {
  const v = settings[name];
  if (v === undefined || v === null || v === "") return SETTINGS[name].default;
  if (v === true || v === "true") return true;
  if (v === false || v === "false") return false;
  fallbacks.push(name);
  return SETTINGS[name].default;
}

/**
 * The connection's cadence and floor from its configuration (cma.connection_config). fallbacks: the
 * settings given out of their range, each replaced by its default.
 */
export function usageSettings(config) {
  const s = config?.settings ?? {};
  const fallbacks = [];
  return {
    formsIntervalMinutes: whole(s, "forms_poll_interval_minutes", fallbacks),
    openCheckMinutes: whole(s, "email_open_check_minutes", fallbacks),
    floorPct: whole(s, "api_daily_floor_pct", fallbacks),
    probe: flag(s, "forms_poll_probe", fallbacks),
    fallbacks,
  };
}

export const minuteOf = (ms) => Math.floor(ms / 60_000);

/**
 * Slots of the forms on a cadence of `every` minutes: by the forms' order (id), the first form slot 0,
 * the next 1, and so on round the interval, so no minute holds more than its share (22 forms every 5
 * minutes: 5, 5, 4, 4, 4). Answers form id → slot.
 */
export function formSlots(formIds, every) {
  return new Map([...new Set(formIds)].sort().map((id, i) => [id, i % Math.max(1, every)]));
}

/**
 * Whether a slot of a cadence of `every` minutes is due in a run at nowMs whose previous run was at
 * lastMs (null: none known): always every minute; when no previous run is known; when a whole interval
 * has passed; else when one of the minutes since the previous run, up to this one, is the slot's
 * (minute mod every).
 */
export function dueInRun(slot, every, lastMs, nowMs) {
  if (every <= 1 || lastMs === null || !Number.isFinite(lastMs)) return true;
  const last = minuteOf(lastMs);
  const now = minuteOf(nowMs);
  if (now - last >= every) return true;
  for (let m = last + 1; m <= now; m += 1) if (m % every === slot) return true;
  return false;
}

/**
 * Whether the open check is due: when none ran before (lastMs null) or `every` minutes have passed
 * since the last one started. Each connection keeps the phase its first check set, so connections'
 * checks fall in different minutes; a check that fails waits for the next one, the nightly reconcile
 * covers the gap.
 */
export function openCheckDue(every, lastMs, nowMs) {
  return lastMs === null || !Number.isFinite(lastMs) || nowMs - lastMs >= every * 60_000;
}

/**
 * The probe's search (forms_poll_probe): one contact whose most recent conversion (recent_conversion_date,
 * the time of the contact's latest form submission) is at or after fromMs; the id only, which is not kept.
 */
export function probeBody(fromMs) {
  return {
    filterGroups: [{ filters: [{ propertyName: "recent_conversion_date", operator: "GTE", value: String(Math.floor(fromMs)) }] }],
    properties: ["hs_object_id"],
    limit: 1,
  };
}
