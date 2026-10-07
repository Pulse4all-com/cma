/**
 * The Team screen's logic (migration 0004): how skills are grouped and labelled, which roles a
 * person may be given, the smallest set of writes an edit needs, the filters and the checks of
 * the Add a person form. Pure and without runtime imports, so verify/team.mjs tests it without a
 * browser or a database. Nothing here branches on a role key, a team key or a skill key: the
 * database says what is assignable and editable, this module only arranges it.
 */
import type { DirectoryPerson, PersonSkill, RoleInfo, SkillDimension, SkillInfo, SkillInput } from "./data/types";

/** Languages first, then work types, then channels, as the directory orders them */
export const DIMENSIONS: readonly SkillDimension[] = ["language", "work_type", "channel"];

/** The catalog grouped per dimension, in catalog order, active skills only */
export function skillsByDimension(catalog: SkillInfo[]): { dimension: SkillDimension; skills: SkillInfo[] }[] {
  return DIMENSIONS
    .map((dimension) => ({
      dimension,
      skills: catalog.filter((s) => s.dimension === dimension && s.isActive).sort((a, b) => a.sortOrder - b.sortOrder || a.key.localeCompare(b.key)),
    }))
    .filter((g) => g.skills.length > 0);
}

/** "Dutch · Fluent" for a scaled skill, the name alone for a held one */
export function skillLabel(s: PersonSkill): string {
  return s.levelName ? `${s.name} · ${s.levelName}` : s.name;
}

/**
 * What the editor holds for a person: per skill key the level, true for a binary skill that is
 * held, and nothing for a skill that is not. The initial state comes from the directory row.
 */
export type SkillState = Record<string, number | true>;

export function skillStateOf(skills: PersonSkill[]): SkillState {
  const out: SkillState = {};
  for (const s of skills) out[s.key] = s.level ?? true;
  return out;
}

/** The payload of PUT …/skills: every held skill, with its level for a scaled dimension */
export function skillsPayload(state: SkillState, catalog: SkillInfo[]): SkillInput[] {
  return Object.entries(state)
    .filter(([key]) => catalog.some((s) => s.key === key && s.isActive))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, v]) => (v === true ? { key } : { key, level: v }));
}

function sameSkills(a: SkillState, b: SkillState): boolean {
  const ka = Object.keys(a).sort();
  const kb = Object.keys(b).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && a[k] === b[k]);
}

/** What an edit may change; a field is left out when it did not change */
export interface EditState {
  roleKey: string | null;
  active: boolean;
  teams: string[];
  skills: SkillState;
}

export interface EditChanges {
  roleKey?: string;
  active?: boolean;
  teams?: string[];
  skills?: SkillInput[];
}

/**
 * The smallest set of writes between the person as opened and as edited: one call per changed
 * part, nothing for an unchanged one, so a role change never rewrites the skills (and the audit
 * log shows only what changed). A role can only change to a value, never back to none.
 */
export function editChanges(initial: EditState, next: EditState, catalog: SkillInfo[]): EditChanges {
  const out: EditChanges = {};
  if (next.roleKey && next.roleKey !== initial.roleKey) out.roleKey = next.roleKey;
  if (next.active !== initial.active) out.active = next.active;
  const ti = [...initial.teams].sort();
  const tn = [...next.teams].sort();
  if (ti.length !== tn.length || ti.some((k, i) => k !== tn[i])) out.teams = tn;
  if (!sameSkills(initial.skills, next.skills)) out.skills = skillsPayload(next.skills, catalog);
  return out;
}

export function hasChanges(c: EditChanges): boolean {
  return Object.keys(c).length > 0;
}

/**
 * The roles a person can be set to: the roles the caller may assign, plus the person's current
 * role when the caller may not assign it (shown, not choosable), so the dropdown always names the
 * role the person holds. In the ladder's order as the database returns it.
 */
export function roleOptions(roles: RoleInfo[], currentKey: string | null): { key: string; name: string; disabled: boolean }[] {
  return roles
    .filter((r) => r.assignable || r.key === currentKey)
    .map((r) => ({ key: r.key, name: r.name, disabled: !r.assignable }));
}

export interface DirectoryFilter {
  showInactive: boolean;
  /** A team key, or "" for every team */
  team: string;
}

/** The rows to show: inactive people only when asked, one team when chosen; the order is the database's */
export function filterPeople(people: DirectoryPerson[], f: DirectoryFilter): DirectoryPerson[] {
  return people.filter((p) => (f.showInactive || p.isActive) && (!f.team || p.teams.some((t) => t.key === f.team)));
}

export interface NewPersonForm {
  displayName: string;
  email: string;
  organisationKey: string;
  roleKey: string;
  loginSystem: string;
  loginId: string;
  timeZone: string;
}

export type NewPersonProblem = "name" | "email" | "employer" | "role" | "login";

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/** The form's own checks, for clear messages before the database checks the same again */
export function checkNewPerson(f: NewPersonForm): NewPersonProblem[] {
  const out: NewPersonProblem[] = [];
  const name = f.displayName.trim();
  if (name.length < 1 || name.length > 100) out.push("name");
  if (!EMAIL_RE.test(f.email.trim())) out.push("email");
  if (!f.organisationKey) out.push("employer");
  if (!f.roleKey) out.push("role");
  const id = f.loginId.trim();
  if (id.length < 1 || id.length > 200 || /\s/.test(id) || f.loginSystem.trim().length < 1) out.push("login");
  return out;
}
