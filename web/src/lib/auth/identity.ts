/**
 * Identity seam.
 *
 * Two layers, one list (README, Authentication):
 *  - Identity: who the visitor is, proven by the gate (IAP). Only the stable
 *    Google account id ("sub") is a match key; the email is display only.
 *  - Principal: who may work, from app_user: tenant, user, role, display name.
 *
 * In this increment getIdentity() and resolvePrincipal() come from the mock
 * provider. The IAP provider (JWT verification in proxy.ts) is the next step;
 * the app_user lookup against Postgres follows with the API.
 */
import { config } from "@/lib/config";
import type { Locale } from "@/lib/copy";

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
}

/** Outcome of the app_user check for a proven identity */
export type Access =
  | { kind: "granted"; identity: Identity; principal: Principal }
  | { kind: "no_access"; identity: Identity };

export interface IdentityProvider {
  /** Returns null when the request carries no verified identity */
  getIdentity(): Promise<Identity | null>;
  resolveAccess(identity: Identity): Promise<Access>;
}

const mockIdentity: Identity = {
  subject: "accounts.google.com:100000000000000000001",
  email: "agent.one@example.com",
};

/** Mirrors db/03_seed_dev_test_data.sql: Agent One, Newco, agent, Pulse4all subscriptions */
const mockPrincipal: Principal = {
  tenantId: "00000000-0000-7000-8000-000000000001",
  tenantName: "Pulse4all subscriptions",
  userId: "00000000-0000-7000-8000-000000000101",
  displayName: "Agent One",
  organisationName: "Newco",
  roleKey: "agent",
  locale: config.defaultLocale,
};

const mockProvider: IdentityProvider = {
  async getIdentity() {
    return mockIdentity;
  },
  async resolveAccess(identity) {
    return { kind: "granted", identity, principal: mockPrincipal };
  },
};

function provider(): IdentityProvider {
  if (config.authMode === "mock") return mockProvider;
  // Replaced by the IAP provider in the next step
  throw new Error("CMA_AUTH_MODE=iap is not wired yet; set CMA_AUTH_MODE=mock");
}

export async function getAccess(): Promise<Access | null> {
  const p = provider();
  const identity = await p.getIdentity();
  if (!identity) return null;
  return p.resolveAccess(identity);
}
