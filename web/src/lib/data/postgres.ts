import "server-only";
import { config } from "@/lib/config";
import type { Identity, Principal } from "@/lib/auth/identity";
import { CmaDbError, one, withTenant, withoutTenant, type Querier, type TenantContext } from "@/lib/db/client";
import type {
  CmaData, DateKey, ExportHoursRow, HoursRange, HoursSummary, StatusChangeRow, StatusTimeRow, TeamDay, TeamDayDetail,
  TeamPerson, TenantSetting, TimeEvent, Workday, WorkStatus,
} from "./types";

/**
 * CmaData against Postgres, as cma_app (migration 0002).
 *
 * Rules every query here follows:
 *  - One transaction per call, tenant and acting user set for that transaction only (lib/db/client).
 *  - Own data only through the database: every read filters on cma.current_user_id(), the
 *    transaction's acting user, never on an id passed in. A bug that hands over a colleague's id
 *    still cannot read a colleague's hours.
 *  - The database clock decides: open_workday(), set_status() and end_workday() are called without
 *    a time, so they use now(). The `now` arguments of the interface exist for the mock only.
 *  - "Today" is the business date in the user's zone, computed in SQL (cma.business_date with
 *    cma.user_timezone), so the app server's zone never matters.
 *  - Errors surface as CmaDbError with the function's SQLSTATE (CMA01 to CMA05); SQL text never
 *    reaches a screen.
 */

/** The acting user's own rows; the value comes from the transaction context, not a parameter */
const OWN = "user_id = cma.current_user_id()";
/** Today's business date for the acting user, in the user's zone */
const TODAY = "cma.business_date(now(), cma.user_timezone(cma.current_user_id()))";
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type HeaderRow = {
  business_date: string;
  status: "open" | "ended";
  started_at: Date;
  ended_at: Date | null;
};
type SummaryRow = HeaderRow & { working_seconds: number };

const HEADER = "business_date, status, started_at, ended_at";

type DayRow = HeaderRow & {
  status_key: string | null;
  status_since: Date | null;
  closed_seconds: number;
  running_since: Date | null;
};

/**
 * One own workday with its current status and the clock's inputs. Worked time counts intervals in
 * statuses with is_working; a capped interval (forgotten clock-out) counts as closed and never runs.
 * `dateSql` is TODAY or a bound parameter, never caller text.
 */
async function readDay(q: Querier, dateSql: string, params: unknown[]): Promise<DayRow[]> {
  const r = await q.query<DayRow>(
    `select s.business_date, s.status, s.started_at, s.ended_at,
            ws.key                                   as status_key,
            coalesce(c.closed_seconds, 0)::int       as closed_seconds,
            c.running_since,
            c.status_since
       from cma.workday_summary s
       left join cma.work_status ws
              on ws.tenant_id = cma.current_tenant_id() and ws.id = s.current_status_id
       left join lateral (
         select sum(i.seconds) filter (where iws.is_working and (not i.is_open or i.is_capped)) as closed_seconds,
                max(i.from_at) filter (where iws.is_working and i.is_open and not i.is_capped)  as running_since,
                max(i.from_at) filter (where i.is_open and not i.is_capped)                     as status_since
           from cma.time_interval i
           join cma.work_status iws
             on iws.tenant_id = cma.current_tenant_id() and iws.id = i.status_id
          where i.workday_id = s.workday_id
       ) c on true
      where s.${OWN} and s.business_date = ${dateSql}`,
    params,
  );
  return r.rows;
}

function ctx(me: Principal): TenantContext {
  return { tenantId: me.tenantId, userId: me.userId };
}

function toWorkday(r: DayRow): Workday {
  const ended = r.status === "ended";
  return {
    date: r.business_date,
    status: ended ? "ended" : "working",
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    statusKey: ended ? null : r.status_key,
    statusSince: !ended && r.status_since ? r.status_since.toISOString() : null,
    clock: {
      closedSeconds: r.closed_seconds,
      runningSince: !ended && r.running_since ? r.running_since.toISOString() : null,
    },
  };
}

/**
 * Minutes shown for a day: working time, rounded down so the screen never shows more than was
 * worked. Which hours the agent's screen shows (working or paid) is an open decision with Arno and
 * Kira (README, Open decisions); switching is this one line.
 */
function minutesOf(r: SummaryRow): number {
  return Math.floor(r.working_seconds / 60);
}

function assertDate(d: string, name: string): void {
  if (!DATE_RE.test(d)) throw new CmaDbError("DB_ERROR", `${name} must be YYYY-MM-DD`);
}

// ---- Team (migrations 0003, 0003a): cma.team_hours, cma.team_day, cma.correct_workday, cma.team_people
// These read other people's days, so the permission check is inside each function (workday.team,
// CMA06), in the same transaction as the read: never a check here followed by a plain query.

type TeamRow = {
  user_id: string;
  display_name: string;
  organisation_name: string;
  business_date: string;
  timezone: string;
  status: "open" | "ended";
  started_at: Date;
  ended_at: Date | null;
  working_seconds: number;
  paid_seconds: number;
  is_capped: boolean;
  needs_correction: boolean;
  has_correction: boolean;
};

type EventRow = {
  event_id: string;
  kind: TimeEvent["kind"];
  status_key: string | null;
  status_name: string | null;
  occurred_at: Date;
  recorded_at: Date;
  source: TimeEvent["source"];
  supersedes_event_id: string | null;
  reason: string | null;
  approved_by_name: string | null;
  is_effective: boolean;
};

function toTeamDay(r: TeamRow): TeamDay {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    status: r.status,
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    minutes: Math.floor(r.working_seconds / 60),
    paidMinutes: Math.floor(r.paid_seconds / 60),
    isCapped: r.is_capped,
    needsCorrection: r.needs_correction,
    hasCorrection: r.has_correction,
  };
}

function toTimeEvent(r: EventRow): TimeEvent {
  return {
    id: r.event_id,
    kind: r.kind,
    statusKey: r.status_key,
    statusName: r.status_name,
    at: r.occurred_at.toISOString(),
    recordedAt: r.recorded_at.toISOString(),
    source: r.source,
    supersedes: r.supersedes_event_id,
    reason: r.reason,
    approvedByName: r.approved_by_name,
    isEffective: r.is_effective,
  };
}

async function readTeamDay(q: Querier, userId: string, date: DateKey): Promise<TeamDayDetail> {
  const day = await q.query<TeamRow>(`select * from cma.team_hours($2::date, $2::date, $1::uuid)`, [userId, date]);
  const events = await q.query<EventRow>(`select * from cma.team_day($1::uuid, $2::date)`, [userId, date]);
  return { day: day.rows[0] ? toTeamDay(day.rows[0]) : null, events: events.rows.map(toTimeEvent) };
}

// ---- Exports (migration 0003b): cma.export_hours, cma.export_status_changes, cma.tenant_settings
// workday.export is checked inside each export function, in the same transaction as the read.
// The settings are read in that same transaction, so a file never mixes two configurations.

async function readSettings(q: Querier): Promise<TenantSetting[]> {
  const r = await q.query<{ key: string; value: string; is_default: boolean }>(`select * from cma.tenant_settings()`);
  return r.rows.map((x) => ({ key: x.key, value: x.value, isDefault: x.is_default }));
}

type ExportHoursDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status: "open" | "ended"; started_at: Date; ended_at: Date | null;
  working_seconds: number; productive_seconds: number; paid_seconds: number;
  billable_seconds: number; is_capped: boolean; needs_correction: boolean; has_correction: boolean;
};

type StatusChangeDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status_key: string; status_name: string; is_working: boolean; is_productive: boolean; is_paid: boolean;
  is_billable: boolean; from_at: Date; to_at: Date | null; is_open: boolean; is_capped: boolean;
  seconds: number; source: StatusChangeRow["source"];
};

function toExportHoursRow(r: ExportHoursDbRow): ExportHoursRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    status: r.status,
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
    workedSeconds: r.working_seconds,
    productiveSeconds: r.productive_seconds,
    paidSeconds: r.paid_seconds,
    billableSeconds: r.billable_seconds,
    isCapped: r.is_capped,
    needsCorrection: r.needs_correction,
    hasCorrection: r.has_correction,
  };
}

type StatusTimeDbRow = {
  user_id: string; display_name: string; organisation_name: string; business_date: string; timezone: string;
  status_key: string; status_name: string; sort_order: number; status_active: boolean; is_working: boolean;
  is_productive: boolean; is_paid: boolean; is_billable: boolean; seconds: number; stretches: number; is_capped: boolean;
};

function toStatusTimeRow(r: StatusTimeDbRow): StatusTimeRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    statusKey: r.status_key,
    statusName: r.status_name,
    sortOrder: r.sort_order,
    statusActive: r.status_active,
    isWorking: r.is_working,
    isProductive: r.is_productive,
    isPaid: r.is_paid,
    isBillable: r.is_billable,
    seconds: r.seconds,
    stretches: r.stretches,
    isCapped: r.is_capped,
  };
}

function toStatusChangeRow(r: StatusChangeDbRow): StatusChangeRow {
  return {
    userId: r.user_id,
    displayName: r.display_name,
    organisationName: r.organisation_name,
    date: r.business_date,
    timeZone: r.timezone,
    statusKey: r.status_key,
    statusName: r.status_name,
    isWorking: r.is_working,
    isProductive: r.is_productive,
    isPaid: r.is_paid,
    isBillable: r.is_billable,
    from: r.from_at.toISOString(),
    to: r.to_at ? r.to_at.toISOString() : null,
    isOpen: r.is_open,
    isCapped: r.is_capped,
    seconds: r.seconds,
    source: r.source,
  };
}

export const postgresData: CmaData = {
  async findPrincipal(identity: Identity): Promise<Principal | null> {
    // 1. Before a tenant is known: the one SECURITY DEFINER lookup, tenant ids only
    const tenants = await withoutTenant((q) =>
      q.query<{ tenant_id: string }>(
        "select tenant_id from cma.find_tenants_for_identity($1, $2)",
        [identity.provider, identity.subject],
      ),
    );
    const match = tenants.rows[0];
    if (!match) return null;
    if (tenants.rows.length > 1) {
      // No tenant picker yet; never guess. Count only: the subject is a personal identifier.
      console.warn(`[cma-data] identity (${identity.provider}) matches ${tenants.rows.length} tenants; no tenant picker yet`);
      return null;
    }
    const tenantId = match.tenant_id;

    // 2. Inside that tenant, as cma_app under row-level security: the app_user check
    return withTenant({ tenantId }, async (q) => {
      const r = await q.query<{
        user_id: string;
        display_name: string;
        tenant_name: string;
        organisation_name: string;
        time_zone: string;
        role_key: string | null;
        permissions: string[];
      }>(
        `select u.id                         as user_id,
                u.display_name,
                t.name                       as tenant_name,
                coalesce(o.name, '')         as organisation_name,
                cma.user_timezone(u.id)      as time_zone,
                -- earliest grant: deterministic without ranking role keys (no hardcoded ladder)
                (select r.key
                   from cma.user_role ur
                   join cma.app_role r on r.tenant_id = ur.tenant_id and r.id = ur.role_id
                  where ur.tenant_id = u.tenant_id and ur.user_id = u.id
                  order by ur.granted_at, r.key
                  limit 1)                   as role_key,
                array(select p from cma.user_permissions(u.id) p order by 1) as permissions
           from cma.app_user_external_id x
           join cma.app_user u      on u.tenant_id = x.tenant_id and u.id = x.user_id
           join cma.tenant t        on t.id = u.tenant_id
           left join cma.organisation o on o.tenant_id = u.tenant_id and o.id = u.organisation_id
          where x.tenant_id   = cma.current_tenant_id()
            and x.system      = $1
            and x.external_id = $2
            and u.status      = 'active'`,
        [identity.provider, identity.subject],
      );
      const row = r.rows[0];
      // No row: deactivated between the two steps. No role: may not work yet. Both: no access yet.
      if (!row || !row.role_key) return null;
      return {
        tenantId,
        tenantName: row.tenant_name,
        userId: row.user_id,
        displayName: row.display_name,
        organisationName: row.organisation_name,
        roleKey: row.role_key,
        permissions: row.permissions,
        locale: config.defaultLocale,
        timeZone: row.time_zone,
      };
    });
  },

  async openWorkday(me: Principal): Promise<Workday> {
    // Returns today's day, open or ended, creating it if needed; an ended day stays ended
    return withTenant(ctx(me), async (q) => {
      const opened = await q.query<{ business_date: string }>(`select business_date from cma.open_workday()`);
      const date = one(opened.rows, "open_workday").business_date;
      return toWorkday(one(await readDay(q, "$1::date", [date]), "open_workday"));
    });
  },

  async getWorkday(me: Principal, date: DateKey): Promise<Workday | null> {
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      const row = (await readDay(q, "$1::date", [date]))[0];
      return row ? toWorkday(row) : null;
    });
  },

  async endWorkday(me: Principal): Promise<Workday> {
    return withTenant(ctx(me), async (q) => {
      // Lock today's own row so two tabs cannot both end it
      const today = await q.query<{ id: string; status: "open" | "ended" }>(
        `select id, status from cma.workday
          where tenant_id = cma.current_tenant_id() and ${OWN} and business_date = ${TODAY}
          for update`,
      );
      const w = today.rows[0];
      if (!w) throw new CmaDbError("CMA02", "no workday today");
      // Same as the mock: ending an ended day returns it, so a repeated log out is harmless
      if (w.status !== "ended") await q.query(`select 1 from cma.end_workday($1)`, [w.id]);
      return toWorkday(one(await readDay(q, TODAY, []), "end_workday"));
    });
  },

  async listStatuses(me: Principal): Promise<WorkStatus[]> {
    return withTenant(ctx(me), async (q) => {
      // Pay and billing flags stay out: not agent information (decision of 6 October 2026)
      const r = await q.query<{ key: string; name: string; is_working: boolean; is_productive: boolean; is_default: boolean }>(
        `select key, name, is_working, is_productive, is_default
           from cma.work_status
          where tenant_id = cma.current_tenant_id() and status = 'active'
          order by sort_order, key`,
      );
      return r.rows.map((s) => ({
        key: s.key, name: s.name, isWorking: s.is_working, isProductive: s.is_productive, isDefault: s.is_default,
      }));
    });
  },

  async setStatus(me: Principal, key: string): Promise<Workday> {
    return withTenant(ctx(me), async (q) => {
      // Today's own day; set_status locks it and enforces own day, not ended, active key
      const today = await q.query<{ id: string }>(
        `select id from cma.workday
          where tenant_id = cma.current_tenant_id() and ${OWN} and business_date = ${TODAY}`,
      );
      const w = today.rows[0];
      if (!w) throw new CmaDbError("CMA02", "no workday today");
      await q.query(`select 1 from cma.set_status($1, $2)`, [w.id, key]);
      return toWorkday(one(await readDay(q, TODAY, []), "set_status"));
    });
  },

  async getHours(me: Principal, range: HoursRange): Promise<HoursSummary> {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<SummaryRow>(
        `select ${HEADER}, working_seconds
           from cma.workday_summary
          where ${OWN} and business_date between $1::date and $2::date
          order by business_date`,
        [range.from, range.to],
      );
      const days = r.rows.map((row) => ({
        date: row.business_date,
        minutes: minutesOf(row),
        startedAt: row.started_at.toISOString(),
        endedAt: row.ended_at ? row.ended_at.toISOString() : null,
      }));
      return { ...range, days, totalMinutes: days.reduce((sum, d) => sum + d.minutes, 0) };
    });
  },

  async getTeamHours(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<TeamRow>(
        `select * from cma.team_hours($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { ...range, days: r.rows.map(toTeamDay) };
    });
  },

  async listTeamPeople(me): Promise<TeamPerson[]> {
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<{ user_id: string; display_name: string; organisation_name: string; timezone: string }>(
        `select * from cma.team_people()`,
      );
      return r.rows.map((p) => ({
        userId: p.user_id,
        displayName: p.display_name,
        organisationName: p.organisation_name,
        timeZone: p.timezone,
      }));
    });
  },

  async getTeamDay(me, userId, date) {
    assertDate(date, "date");
    return withTenant(ctx(me), (q) => readTeamDay(q, userId, date));
  },

  async correctWorkday(me, userId, date, correction) {
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      // The function validates everything again; the route's checks only give clearer 400s
      await q.query(`select 1 from cma.correct_workday($1::uuid, $2::date, $3::jsonb, $4)`, [
        userId,
        date,
        JSON.stringify(correction.changes),
        correction.reason,
      ]);
      // A new statement sees the edit (one transaction, read committed)
      return readTeamDay(q, userId, date);
    });
  },

  async listSettings(me) {
    return withTenant(ctx(me), (q) => readSettings(q));
  },

  async exportHours(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      // The export function first: without workday.export it refuses before anything else is read
      const r = await q.query<ExportHoursDbRow>(
        `select * from cma.export_hours($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { settings: await readSettings(q), rows: r.rows.map(toExportHoursRow) };
    });
  },

  async exportStatusChanges(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<StatusChangeDbRow>(
        `select * from cma.export_status_changes($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { settings: await readSettings(q), rows: r.rows.map(toStatusChangeRow) };
    });
  },

  // Addition 0003c: the permission (performance.team) is checked inside the function, in the same
  // transaction as the read
  async getTeamStatusTime(me, range, userId) {
    assertDate(range.from, "from");
    assertDate(range.to, "to");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<StatusTimeDbRow>(
        `select * from cma.team_status_time($1::date, $2::date, $3::uuid)`,
        [range.from, range.to, userId],
      );
      return { ...range, rows: r.rows.map(toStatusTimeRow) };
    });
  },
};
