/**
 * Identity seam.
 *
 * Two layers, one list (README, Authentication):
 *  - Identity: who the visitor is, proven by the gate. In iap mode proxy.ts
 *    verifies IAP's signed token and passes the result on in request headers
 *    that only proxy.ts can set. In mock mode proxy.ts passes a test identity
 *    the same way. Only the provider plus the provider's stable id form the
 *    match key; the email is display only.
 *  - Principal: who may work, from app_user: tenant, user, role, employer. This
 *    is data, so the data layer answers it (mock now, Postgres with the API).
 */
import { cookies, headers } from "next/headers";
import { cache } from "react";
import { config } from "@/lib/config";
import type { Locale } from "@/lib/copy";
import { data } from "@/lib/data";
import { applyPreview, isRoleKey, mayPreview, PREVIEW_COOKIE } from "./preview";

export interface Identity {
  /**
   * The identity system that proved the subject, as stored in
   * app_user_external_id.system: "google" behind IAP, "mock" in dev.
   * A data value, never a code path: another provider is another value.
   */
  provider: string;
  /** Stable account id at the identity provider; with provider, the only match key */
  subject: string;
  /** Display only, never used for matching */
  email: string;
}

export interface Principal {
  tenantId: string;
  tenantName: string;
  userId: string;
  displayName: string;
  organisationName: string;
  roleKey: string;
  /**
   * Permission keys from the catalog (cma.user_permissions), for showing or hiding screens only.
   * Screens check a permission, never a role key. The database checks again on every call.
   */
  permissions: string[];
  locale: Locale;
  /** IANA zone the user works in; calendar days and week boundaries follow it */
  timeZone: string;
  /**
   * Preview as role (16 October 2026, lib/auth/preview): the role an admin is looking through, or null.
   * While set, `permissions` is the intersection of the real set and the role's set: a preview narrows,
   * never widens, and never changes who the person is (user, tenant, day, hours, the audit's actor).
   */
  preview: { roleKey: string; roleName: string } | null;
  /** The real permissions hold users.manage_all, computed before the narrowing, so the control stays while previewing */
  canPreview: boolean;
  /**
   * The per-person report pages the tenant switched on (setting reports.per_person, addition 0008t): keys from
   * email, orders and (since addition 0008y) attempts. A page in the list shows to people holding performance.team; one not in it is absent (its
   * rail item and its route); the database refuses the read as well (CMA06)
   */
  perPerson: string[];
}

/** Outcome of the app_user check for a proven identity */
export type Access =
  /** principal: as the screens and the API see it (narrowed while previewing); real: as the database sees it */
  | { kind: "granted"; identity: Identity; principal: Principal; real: Principal }
  | { kind: "no_access"; identity: Identity };

/** Set by proxy.ts only; it strips any incoming copy before setting its own */
export const IDENTITY_HEADERS = {
  provider: "x-cma-identity-provider",
  subject: "x-cma-identity-sub",
  email: "x-cma-identity-email",
} as const;

/**
 * Dev test identities live under system "mock" (db/06_seed_dev_time_model.sql:
 * agent-one, agent-two, supervisor, manager), so a mock subject can never match
 * or impersonate a real Google row.
 */
export const MOCK_PROVIDER = "mock";

/** The default mock identity when a request does not choose one */
export const MOCK_IDENTITY: Identity = {
  provider: MOCK_PROVIDER,
  subject: "agent-one",
  email: "agent-one@example.com",
};

/** Mock-mode identity for any test subject; the email is display only */
export function mockIdentity(subject: string): Identity {
  return { provider: MOCK_PROVIDER, subject, email: `${subject}@example.com` };
}

/** Mirrors the in-memory mock data: Agent One, Newco, agent, Pulse4all subscriptions */
export const MOCK_PRINCIPAL: Principal = {
  tenantId: "00000000-0000-7000-8000-000000000001",
  tenantName: "Pulse4all subscriptions",
  userId: "00000000-0000-7000-8000-000000000101",
  displayName: "Agent One",
  organisationName: "Newco",
  roleKey: "agent",
  permissions: ["workday.own", "roster.view"],
  locale: config.defaultLocale,
  timeZone: "Europe/Madrid",
  preview: null,
  canPreview: false,
  // the dev seed (03) switches the three on (attempts since addition 0008y)
  perPerson: ["email", "orders", "attempts"],
};

/** The identity proxy.ts attached to this request, or null if it attached none */
export async function getIdentity(): Promise<Identity | null> {
  const h = await headers();
  const provider = h.get(IDENTITY_HEADERS.provider);
  const subject = h.get(IDENTITY_HEADERS.subject);
  const email = h.get(IDENTITY_HEADERS.email);
  if (!provider || !subject || !email) return null;
  return { provider, subject, email };
}

/**
 * Who is here and whether they may work. Memoised per request (React cache), so a page and the Shell
 * inside it read the principal once. The principal the screens get is narrowed by the preview cookie when
 * the real principal may preview (lib/auth/preview); `real` is the person as the database sees them.
 */
export const getAccess = cache(async (): Promise<Access | null> => {
  const identity = await getIdentity();
  if (!identity) return null;
  const found = await data().findPrincipal(identity);
  if (!found) return { kind: "no_access", identity };
  const real: Principal = { ...found, canPreview: mayPreview(found.permissions), preview: null };
  return { kind: "granted", identity, principal: await previewed(real), real };
});

/**
 * The tenant's roles as the real principal reads them, once per request (React cache): the preview and the
 * Shell's select both need the list, and before the IT audit of 17 October 2026 an admin's page read it twice
 */
export const rolesOf = cache((real: Principal) => data().listRoles(real));

/** The principal as the pages and the API see it: narrowed when an admin's preview cookie names a known role */
async function previewed(real: Principal): Promise<Principal> {
  if (!real.canPreview) return real;
  const roleKey = (await cookies()).get(PREVIEW_COOKIE)?.value;
  if (!isRoleKey(roleKey)) return real;
  try {
    return applyPreview(real, roleKey, await rolesOf(real));
  } catch (e) {
    // A role list that cannot be read is no preview: the admin keeps their own view
    console.warn(`[cma-auth] preview ignored: ${e instanceof Error ? e.message : String(e)}`);
    return real;
  }
}
