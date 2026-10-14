/**
 * Invitations by email (addition 0008l): the logic the People screen, the invitation routes and the
 * /invite page share. Pure and without runtime imports, so verify/invitations.mjs tests it without a
 * browser or a database. Nothing here branches on a role, team or skill key: the database says which
 * roles the caller may grant (cma.roles), this module only arranges them.
 *
 * The token travels once: in the answer to create or renew, into the link the inviter sends from their
 * own mail client. A list never carries it, and the database keeps only its hash.
 */
import type { Invitation, InvitationPreview, InvitationState, PersonSkill, RoleInfo } from "./data/types";

/** A link's token: 32 bytes as 43 url-safe base64 characters (cma.invitation_new_token) */
export const INVITE_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const KEY_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const ROLE_RE = /^[a-z_]+$/;
const LOCALE_RE = /^[a-z]{2}$/;

/**
 * The roles an invitation may carry for this caller: the ones cma.roles() marks assignable, in the
 * ladder's order. The system role never appears (cma.roles lists assignable rows only), and a
 * users.manage_agents holder sees only the roles they may grant.
 */
export function inviteRoleOptions(roles: RoleInfo[]): { key: string; name: string }[] {
  return roles.filter((r) => r.assignable).map((r) => ({ key: r.key, name: r.name }));
}

export interface InviteForm {
  email: string;
  displayName: string;
  locale: string;
  roleKey: string;
  organisationKey: string;
  teamKeys: string[];
  /** Per skill key the level for a scaled dimension, true for a binary one */
  skills: Record<string, number | true>;
}

export type InviteProblem = "email" | "name" | "locale" | "role" | "employer";

/** What the dialog asks before sending: the same checks the route and the database make again */
export function checkInvite(f: InviteForm, locales: readonly string[]): InviteProblem[] {
  const out: InviteProblem[] = [];
  if (!EMAIL_RE.test(f.email.trim()) || f.email.trim().length > 200) out.push("email");
  const name = f.displayName.trim();
  if (name.length < 1 || name.length > 100) out.push("name");
  if (!locales.includes(f.locale)) out.push("locale");
  if (!f.roleKey) out.push("role");
  if (!f.organisationKey) out.push("employer");
  return out;
}

/** The body of POST /api/v1/team/invitations from the dialog's state; skills in key order */
export function invitePayload(f: InviteForm) {
  return {
    email: f.email.trim(),
    displayName: f.displayName.trim(),
    locale: f.locale,
    roleKey: f.roleKey,
    organisationKey: f.organisationKey,
    teamKeys: [...f.teamKeys].sort(),
    skills: Object.entries(f.skills)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, v]) => (v === true ? { key } : { key, level: v })),
  };
}

export interface InvitationInput {
  email: string;
  displayName: string;
  locale: string;
  roleKey: string;
  organisationKey: string;
  teamKeys: string[];
  skills: { key: string; level?: number }[];
}

/**
 * The route's shape checks of a create body; the rules (role ceiling, catalogs, scale, addresses
 * already known) are the database's. Answers the input or the first problem as text.
 */
export function parseInvitationInput(b: Record<string, unknown>, locales: readonly string[]): { input: InvitationInput } | { problem: string } {
  const text = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const email = text(b.email).toLowerCase();
  if (!EMAIL_RE.test(email) || email.length > 200) return { problem: "email must be an email address" };
  const displayName = text(b.displayName);
  if (displayName.length < 1 || displayName.length > 100) return { problem: "displayName must be 1 to 100 characters" };
  const locale = text(b.locale);
  if (!LOCALE_RE.test(locale) || !locales.includes(locale)) return { problem: `locale must be one of ${locales.join(", ")}` };
  const roleKey = text(b.roleKey);
  const organisationKey = text(b.organisationKey);
  if (!ROLE_RE.test(roleKey) || roleKey.length > 60 || !KEY_RE.test(organisationKey) || organisationKey.length > 60) {
    return { problem: "roleKey and organisationKey must be keys" };
  }
  const teamKeys = b.teamKeys ?? [];
  if (!Array.isArray(teamKeys) || teamKeys.length > 50 || !teamKeys.every((k) => typeof k === "string" && KEY_RE.test(k))) {
    return { problem: "teamKeys must be a list of team keys" };
  }
  const skills = b.skills ?? [];
  if (!Array.isArray(skills) || skills.length > 100) return { problem: "skills must be a list of { key, level }" };
  const outSkills: { key: string; level?: number }[] = [];
  for (const s of skills) {
    if (!s || typeof s !== "object" || typeof (s as { key?: unknown }).key !== "string" || !KEY_RE.test((s as { key: string }).key)) {
      return { problem: "skills must be a list of { key, level }" };
    }
    const level = (s as { level?: unknown }).level;
    if (level !== undefined && level !== null && (typeof level !== "number" || !Number.isInteger(level) || level < 1 || level > 9)) {
      return { problem: "a skill level is a whole number from 1 to 9" };
    }
    outSkills.push(level === undefined || level === null ? { key: (s as { key: string }).key } : { key: (s as { key: string }).key, level });
  }
  return { input: { email, displayName, locale, roleKey, organisationKey, teamKeys: [...new Set(teamKeys as string[])], skills: outSkills } };
}

/** The link the inviter sends: the page's own origin (never the container's host) and the token */
export function invitationLink(origin: string, token: string): string | null {
  if (!INVITE_TOKEN_RE.test(token)) return null;
  let u: URL;
  try {
    u = new URL(origin);
  } catch {
    return null;
  }
  if (u.protocol !== "https:" && u.hostname !== "localhost") return null;
  return `${u.origin}/invite/${token}`;
}

/** The mail's wording in the invitee's language (copy.ts, invitationMail) */
export interface MailCopy {
  languageName: string;
  subject: string;
  body: string;
}

export interface MailValues {
  /** The invitee's address, the mail's recipient */
  email: string;
  /** The invitee's name as the inviter typed it */
  name: string;
  /** The inviter's display name */
  inviter: string;
  /** The tenant's display name (the Workspace they join) */
  workspace: string;
  role: string;
  link: string;
  /** The expiry as the invitee reads it, written in their language (lib/time fmtDateTime) */
  expires: string;
}

function fill(template: string, values: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (m, k: string) => (k in values ? values[k]! : m));
}

/**
 * Subject, body and the mailto address of the invitation mail, built from the copy and the values only.
 * Line breaks as CRLF, everything percent-encoded (RFC 6068), the address with its @ readable.
 */
export function invitationMail(c: MailCopy, v: MailValues): { subject: string; body: string; href: string } {
  const values = { name: v.name, inviter: v.inviter, workspace: v.workspace, role: v.role, link: v.link, email: v.email, expires: v.expires };
  const subject = fill(c.subject, values);
  const body = fill(c.body, values).replace(/\r?\n/g, "\r\n");
  const to = encodeURIComponent(v.email).replace(/%40/g, "@");
  return { subject, body, href: `mailto:${to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}` };
}

/** What /invite/<token> shows for the preview's answer; a person of that tenant goes home */
export type InviteView =
  | { kind: "home" }
  | { kind: "open"; tenantName: string; roleName: string; email: string }
  | { kind: "wrong_account"; invitedEmail: string; currentEmail: string }
  | { kind: "expired"; tenantName: string | null }
  | { kind: "other_tenant"; tenantName: string | null }
  | { kind: "invalid" };

export function inviteView(p: InvitationPreview, currentEmail: string): InviteView {
  switch (p.result) {
    case "already_member":
      return { kind: "home" };
    case "open":
      return { kind: "open", tenantName: p.tenantName ?? "", roleName: p.roleName ?? "", email: p.invitedEmail ?? currentEmail };
    case "wrong_account":
      return { kind: "wrong_account", invitedEmail: p.invitedEmail ?? "", currentEmail };
    case "expired":
      return { kind: "expired", tenantName: p.tenantName };
    case "other_tenant":
      return { kind: "other_tenant", tenantName: p.tenantName };
    default:
      return { kind: "invalid" };
  }
}

/** The order of the Invitations section: open, then expired, then accepted, then revoked; newest first within */
const STATE_ORDER: Record<InvitationState, number> = { open: 0, expired: 1, accepted: 2, revoked: 3 };

export function sortInvitations(rows: Invitation[]): Invitation[] {
  return [...rows].sort((a, b) => STATE_ORDER[a.state] - STATE_ORDER[b.state] || b.createdAt.localeCompare(a.createdAt));
}

/** Whether a row may get a new link or be revoked */
export function invitationActionable(i: Invitation): boolean {
  return i.state === "open" || i.state === "expired";
}

/** cma.invitations() as the database answers it */
export interface InvitationDbRow {
  invitation_id: string;
  email: string;
  display_name: string;
  locale: string;
  role_key: string;
  role_name: string;
  organisation_key: string;
  organisation_name: string;
  teams: { key: string; name: string }[] | null;
  skills: PersonSkill[] | null;
  state: InvitationState;
  created_at: Date | string;
  created_by_name: string;
  expires_at: Date | string;
  renewed_at: Date | string | null;
  accepted_at: Date | string | null;
  accepted_user_id: string | null;
  accepted_name: string | null;
  revoked_at: Date | string | null;
  revoked_by_name: string | null;
}

const iso = (v: Date | string | null): string | null => (v === null ? null : typeof v === "string" ? new Date(v).toISOString() : v.toISOString());

/** One list row: named fields only, so nothing else a row might carry (a token, a hash) reaches an answer */
export function invitationFromDb(r: InvitationDbRow): Invitation {
  return {
    invitationId: r.invitation_id,
    email: r.email,
    displayName: r.display_name,
    locale: r.locale,
    roleKey: r.role_key,
    roleName: r.role_name,
    organisationKey: r.organisation_key,
    organisationName: r.organisation_name,
    teams: (r.teams ?? []).map((t) => ({ key: t.key, name: t.name })),
    skills: (r.skills ?? []).map((s) => ({ dimension: s.dimension, key: s.key, name: s.name, level: s.level ?? null, levelName: s.levelName ?? null })),
    state: r.state,
    createdAt: iso(r.created_at)!,
    createdByName: r.created_by_name,
    expiresAt: iso(r.expires_at)!,
    renewedAt: iso(r.renewed_at),
    acceptedAt: iso(r.accepted_at),
    acceptedUserId: r.accepted_user_id,
    acceptedName: r.accepted_name,
    revokedAt: iso(r.revoked_at),
    revokedByName: r.revoked_by_name,
  };
}

// ---- The two settings (Configuration → Exports, Invitations), checked as cma.check_tenant_setting does ----

export const INVITATION_SETTING_KEYS = ["auth.invitation_valid_days", "auth.invitation_email_domains"] as const;

/** auth.invitation_valid_days: a whole number from 1 to 30, or null */
export function parseValidDays(text: string): number | null {
  const v = text.trim();
  if (!/^\d{1,2}$/.test(v)) return null;
  const n = Number(v);
  return n >= 1 && n <= 30 ? n : null;
}

const DOMAIN = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+";
const DOMAIN_LIST_RE = new RegExp(`^${DOMAIN}(,${DOMAIN})*$`);

/**
 * auth.invitation_email_domains as the database stores it: lower case, no spaces, comma-separated; "" for
 * no domain check; null when it is not a list of domain names
 */
export function normaliseDomains(text: string): string | null {
  const v = text.replace(/\s+/g, "").toLowerCase();
  if (v === "") return "";
  return v.length <= 100 && DOMAIN_LIST_RE.test(v) ? v : null;
}
