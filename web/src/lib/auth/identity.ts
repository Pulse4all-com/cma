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
import { headers } from "next/headers";
import { config } from "@/lib/config";
import type { Locale } from "@/lib/copy";
import { data } from "@/lib/data";

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
}

/** Outcome of the app_user check for a proven identity */
export type Access =
  | { kind: "granted"; identity: Identity; principal: Principal }
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

export async function getAccess(): Promise<Access | null> {
  const identity = await getIdentity();
  if (!identity) return null;
  const principal = await data().findPrincipal(identity);
  return principal ? { kind: "granted", identity, principal } : { kind: "no_access", identity };
}
