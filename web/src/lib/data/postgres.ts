import "server-only";
import { config } from "@/lib/config";
import type { Identity, Principal } from "@/lib/auth/identity";
import { CmaDbError, withTenant, withoutTenant, type TenantContext } from "@/lib/db/client";
import type { CmaData, DateKey, HoursRange, HoursSummary, Workday } from "./types";

/**
 * CmaData against Postgres, as cma_app (migration 0002).
 *
 * Rules every query here follows:
 *  - One transaction per call, tenant and acting user set for that transaction only (lib/db/client).
 *  - Own data only through the database: every read filters on cma.current_user_id(), the
 *    transaction's acting user, never on an id passed in. A bug that hands over a colleague's id
 *    still cannot read a colleague's hours.
 *  - The database clock decides: open_workday() and end_workday() are called without a time, so
 *    they use now(). The `now` arguments of the interface exist for the mock only.
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

function ctx(me: Principal): TenantContext {
  return { tenantId: me.tenantId, userId: me.userId };
}

function toWorkday(r: HeaderRow): Workday {
  return {
    date: r.business_date,
    status: r.status === "ended" ? "ended" : "working",
    startedAt: r.started_at.toISOString(),
    endedAt: r.ended_at ? r.ended_at.toISOString() : null,
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

export const postgresData: CmaData = {
  async findPrincipal(identity: Identity): Promise<Principal | null> {
    // 1. Before a tenant is known: the one SECURITY DEFINER lookup, tenant ids only
    const tenants = await withoutTenant((q) =>
      q.query<{ tenant_id: string }>(
        "select tenant_id from cma.find_tenants_for_identity($1, $2)",
        [identity.provider, identity.subject],
      ),
    );
    if (tenants.rows.length === 0) return null;
    if (tenants.rows.length > 1) {
      // No tenant picker yet; never guess. Count only: the subject is a personal identifier.
      console.warn(`[cma-data] identity (${identity.provider}) matches ${tenants.rows.length} tenants; no tenant picker yet`);
      return null;
    }
    const tenantId = tenants.rows[0].tenant_id;

    // 2. Inside that tenant, as cma_app under row-level security: the app_user check
    return withTenant({ tenantId }, async (q) => {
      const r = await q.query<{
        user_id: string;
        display_name: string;
        tenant_name: string;
        organisation_name: string;
        time_zone: string;
        role_key: string | null;
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
                  limit 1)                   as role_key
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
        locale: config.defaultLocale,
        timeZone: row.time_zone,
      };
    });
  },

  async openWorkday(me: Principal): Promise<Workday> {
    // Returns today's day, open or ended, creating it if needed; an ended day stays ended
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<HeaderRow>(`select ${HEADER} from cma.open_workday()`);
      return toWorkday(r.rows[0]);
    });
  },

  async getWorkday(me: Principal, date: DateKey): Promise<Workday | null> {
    assertDate(date, "date");
    return withTenant(ctx(me), async (q) => {
      const r = await q.query<HeaderRow>(
        `select ${HEADER} from cma.workday_summary where ${OWN} and business_date = $1::date`,
        [date],
      );
      return r.rows[0] ? toWorkday(r.rows[0]) : null;
    });
  },

  async endWorkday(me: Principal): Promise<Workday> {
    return withTenant(ctx(me), async (q) => {
      // Lock today's own row so two tabs cannot both end it
      const today = await q.query<HeaderRow & { id: string }>(
        `select id, ${HEADER} from cma.workday
          where tenant_id = cma.current_tenant_id() and ${OWN} and business_date = ${TODAY}
          for update`,
      );
      const w = today.rows[0];
      if (!w) throw new CmaDbError("CMA02", "no workday today");
      // Same as the mock: ending an ended day returns it, so a repeated log out is harmless
      if (w.status === "ended") return toWorkday(w);
      const ended = await q.query<HeaderRow>(`select ${HEADER} from cma.end_workday($1)`, [w.id]);
      return toWorkday(ended.rows[0]);
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
};
