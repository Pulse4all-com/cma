/**
 * Identity seam.
 *
 * Two layers, one list (README, Authentication):
 *  - Identity: who the visitor is, proven by the gate. In iap mode proxy.ts
 *    verifies IAP's signed token and passes the result on in request headers
 *    that only proxy.ts can set. In mock mode proxy.ts passes a fixed test
 *    identity the same way. Only the provider's stable id is a match key; the
 *    email is display only.
 *  - Principal: who may work, from app_user: tenant, user, role, employer. This
 *    is data, so the data layer answers it (mock now, Postgres with the API).
 */
import { headers } from "next/headers";
import { config } from "@/lib/config";
import type { Locale } from "@/lib/copy";
import { data } from "@/lib/data";

export interface Identity {
  /** Stable account id at the identity provider; the only match key */
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
  subject: "x-cma-identity-sub",
  email: "x-cma-identity-email",
} as const;

export const MOCK_IDENTITY: Identity = {
  subject: "accounts.google.com:100000000000000000001",
  email: "agent.one@example.com",
};

/** Mirrors db/03_seed_dev_test_data.sql: Agent One, Newco, agent, Pulse4all subscriptions */
export const MOCK_PRINCIPAL: Principal = {
  tenantId: "00000000-0000-7000-8000-000000000001",
  tenantName: "Pulse4all subscriptions",
  userId: "00000000-0000-7000-8000-000000000101",
  displayName: "Agent One",
  organisationName: "Newco",
  roleKey: "agent",
  locale: config.defaultLocale,
  timeZone: "Europe/Madrid",
};

/** The identity proxy.ts attached to this request, or null if it attached none */
export async function getIdentity(): Promise<Identity | null> {
  const h = await headers();
  const subject = h.get(IDENTITY_HEADERS.subject);
  const email = h.get(IDENTITY_HEADERS.email);
  if (!subject || !email) return null;
  return { subject, email };
}

export async function getAccess(): Promise<Access | null> {
  const identity = await getIdentity();
  if (!identity) return null;
  const principal = await data().findPrincipal(identity);
  return principal ? { kind: "granted", identity, principal } : { kind: "no_access", identity };
}
