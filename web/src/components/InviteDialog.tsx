"use client";

/**
 * Invite someone (addition 0008l), one native <dialog> mounted per opening. Two modes:
 *   create  the form: work email, name, the invitation's language, a role from the ones the caller may
 *           give (cma.roles, assignable only; the system role is never listed), employer, teams and,
 *           with skills.manage, skills; then the link
 *   link    the link of a renewed invitation (New link in the Invitations section)
 * The link is shown with Copy link and Open in mail: a mailto with the subject and body from copy.ts in
 * the invitee's language. The Workspace sends no email; the token is in this answer only and never read
 * back. After Done the page re-reads itself.
 *
 * Keyboard: Tab through the fields, Ctrl+Enter creates, Esc closes (twice with unsaved changes).
 */
import { useEffect, useId, useMemo, useRef, useState, useTransition } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { InvitationLink, OrganisationInfo, RoleInfo, SkillInfo, TeamInfo } from "@/lib/data";
import {
  checkInvite, invitationLink, invitationMail, invitePayload, inviteRoleOptions,
  type InviteForm, type InviteProblem, type MailCopy,
} from "@/lib/invitations";
import { skillsByDimension } from "@/lib/team";
import { fmtDateTime } from "@/lib/time";
import { Button, LinkButton, Notice } from "./primitives";

export type InviteDialogMode =
  | { kind: "create" }
  | { kind: "link"; link: InvitationLink; invitation: { email: string; displayName: string; locale: string; roleName: string } };

export interface InviteContext {
  roles: RoleInfo[];
  teams: TeamInfo[];
  skills: SkillInfo[];
  organisations: OrganisationInfo[];
  maySetSkills: boolean;
  /** The mail's wording per copy locale (copy.ts, invitationMail) */
  mailCopy: Record<string, MailCopy>;
  /** The caller's own language: the screen's, and preselected for a new invitation */
  screenLocale: Locale;
  inviterName: string;
  workspaceName: string;
  timeZone: string;
}

const field = "h-10 rounded-input border border-p4a-border bg-white px-3 text-body text-p4a-body focus:border-p4a-deepblue";
const label = "flex flex-col gap-2 text-small font-semibold text-p4a-body";

export function InviteDialog({ mode, context, copy, onClose, onDone }: {
  mode: InviteDialogMode;
  context: InviteContext;
  copy: Copy;
  onClose: () => void;
  /** After a link was made: the page re-reads the list */
  onDone: () => void;
}) {
  const t = copy.invitations;
  const ref = useRef<HTMLDialogElement>(null);
  const [pending, startTransition] = useTransition();
  const [armed, setArmed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [problems, setProblems] = useState<InviteProblem[]>([]);
  const [copied, setCopied] = useState(false);
  const locales = useMemo(() => Object.keys(context.mailCopy), [context.mailCopy]);
  const empty: InviteForm = useMemo(() => ({
    email: "", displayName: "", locale: locales.includes(context.screenLocale) ? context.screenLocale : locales[0] ?? "",
    roleKey: "", organisationKey: context.organisations.length === 1 ? context.organisations[0]!.key : "", teamKeys: [], skills: {},
  }), [locales, context.screenLocale, context.organisations]);
  const [form, setForm] = useState<InviteForm>(empty);
  const [made, setMade] = useState<Extract<InviteDialogMode, { kind: "link" }> | null>(mode.kind === "link" ? mode : null);
  const roles = inviteRoleOptions(context.roles);
  const groups = useMemo(() => skillsByDimension(context.skills), [context.skills]);
  const dirty = !made && JSON.stringify(form) !== JSON.stringify(empty);

  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);

  function close() {
    if (dirty && !armed) {
      setArmed(true);
      return;
    }
    if (made) onDone();
    else onClose();
  }

  function messageFor(status: number): string {
    if (status === 403) return t.notPermitted;
    if (status === 404) return t.notFound;
    if (status === 409) return t.conflict;
    if (status === 400) return t.invalid;
    return t.failed;
  }

  function create() {
    if (made) return;
    setError(null);
    const found = checkInvite(form, locales);
    setProblems(found);
    if (found.length > 0) return;
    startTransition(async () => {
      const res = await fetch("/api/v1/team/invitations", {
        method: "POST",
        headers: { "content-type": "application/json", "x-cma-request": "1" },
        body: JSON.stringify(invitePayload(form)),
      });
      if (!res.ok) {
        setError(messageFor(res.status));
        return;
      }
      const link = (await res.json()).data as InvitationLink;
      setMade({
        kind: "link", link,
        invitation: { email: form.email.trim().toLowerCase(), displayName: form.displayName.trim(), locale: form.locale,
                      roleName: roles.find((r) => r.key === form.roleKey)?.name ?? "" },
      });
    });
  }

  function setSkill(key: string, value: number | true | null) {
    setForm((f) => {
      const next = { ...f.skills };
      if (value === null) delete next[key];
      else next[key] = value;
      return { ...f, skills: next };
    });
  }

  // The link and the mail, in the invitee's language
  const view = made ? (() => {
    const href = invitationLink(window.location.origin, made.link.token) ?? "";
    const loc = (locales.includes(made.invitation.locale) ? made.invitation.locale : empty.locale) as Locale;
    const expires = fmtDateTime(made.link.expiresAt, context.timeZone, loc);
    const mail = invitationMail(context.mailCopy[loc]!, {
      email: made.invitation.email, name: made.invitation.displayName, inviter: context.inviterName,
      workspace: context.workspaceName, role: made.invitation.roleName, link: href, expires,
    });
    return { href, mail, expiresHere: fmtDateTime(made.link.expiresAt, context.timeZone, context.screenLocale) };
  })() : null;

  /** The dialog is named by its title for assistive tech (the IT audit of 17 October 2026) */
  const titleId = useId();

  return (
    <dialog
      ref={ref}
      data-testid="invite-dialog"
      aria-labelledby={titleId}
      className="m-auto w-[44rem] max-w-[calc(100vw-4rem)] rounded-card border border-p4a-border bg-white p-0 text-p4a-body backdrop:bg-p4a-inkt/40"
      onCancel={(e) => {
        e.preventDefault();
        close();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          create();
        }
        if (e.key !== "Escape") setArmed(false);
      }}
    >
      <div className="flex flex-col gap-6 p-6">
        <header>
          <h2 id={titleId} className="text-panel font-semibold text-p4a-heading">
            {made ? (mode.kind === "link" ? t.renewTitle : t.readyTitle) : t.dialogTitle}
          </h2>
          {made && view ? (
            <p className="mt-1 text-small text-p4a-muted">
              {(mode.kind === "link" ? t.renewBody : t.readyBody).replace("{email}", made.invitation.email).replace("{expires}", view.expiresHere)}
            </p>
          ) : (
            <p className="mt-1 text-small text-p4a-muted">{t.dialogIntro}</p>
          )}
        </header>

        {made && view ? (
          <div className="flex flex-col gap-4" data-testid="invite-link">
            <label className={label}>
              {t.link}
              <input className={`${field} tabular`} readOnly value={view.href} autoFocus onFocus={(e) => e.currentTarget.select()} />
            </label>
            <div className="flex flex-wrap items-center gap-3">
              <Button
                variant="primary"
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText(view.href);
                    setCopied(true);
                  } catch {
                    setCopied(false);
                  }
                }}
              >
                {t.copyLink}
              </Button>
              <LinkButton variant="outlined" href={view.mail.href}>{t.openInMail}</LinkButton>
              {copied ? <span className="text-small text-p4a-success" role="status">{t.copied}</span> : null}
            </div>
            <p className="text-caption text-p4a-grey">{t.noMail}</p>
          </div>
        ) : (
          <div className="flex flex-col gap-6">
            <div className="grid grid-cols-2 gap-4">
              <label className={label}>
                {t.email}
                <input className={field} type="email" value={form.email} autoFocus maxLength={200} autoComplete="off"
                  onChange={(e) => setForm({ ...form, email: e.target.value })} />
                {problems.includes("email") ? <span className="text-caption font-normal text-p4a-error">{t.problemEmail}</span> : null}
              </label>
              <label className={label}>
                {t.name}
                <input className={field} value={form.displayName} maxLength={100} onChange={(e) => setForm({ ...form, displayName: e.target.value })} />
                {problems.includes("name") ? <span className="text-caption font-normal text-p4a-error">{t.problemName}</span> : null}
              </label>
              <label className={label}>
                {t.role}
                <select className={field} value={form.roleKey} onChange={(e) => setForm({ ...form, roleKey: e.target.value })} data-testid="invite-role">
                  <option value="">{t.chooseRole}</option>
                  {roles.map((r) => <option key={r.key} value={r.key}>{r.name}</option>)}
                </select>
                <span className="text-caption font-normal text-p4a-grey">{t.roleHint}</span>
                {problems.includes("role") ? <span className="text-caption font-normal text-p4a-error">{t.problemRole}</span> : null}
              </label>
              <label className={label}>
                {t.employer}
                <select className={field} value={form.organisationKey} onChange={(e) => setForm({ ...form, organisationKey: e.target.value })}>
                  <option value="">{t.chooseEmployer}</option>
                  {context.organisations.map((o) => <option key={o.key} value={o.key}>{o.name}</option>)}
                </select>
                {problems.includes("employer") ? <span className="text-caption font-normal text-p4a-error">{t.problemEmployer}</span> : null}
              </label>
              <label className={label}>
                {t.language}
                <select className={field} value={form.locale} onChange={(e) => setForm({ ...form, locale: e.target.value })}>
                  {locales.map((l) => <option key={l} value={l}>{context.mailCopy[l]!.languageName}</option>)}
                </select>
                {problems.includes("locale") ? <span className="text-caption font-normal text-p4a-error">{t.problemLocale}</span> : null}
              </label>
            </div>

            {context.teams.length > 0 ? (
              <fieldset className="flex flex-col gap-2">
                <legend className="mb-2 text-small font-semibold">{t.teams} <span className="font-normal text-p4a-grey">· {t.teamsHint}</span></legend>
                <div className="grid grid-cols-3 gap-2">
                  {context.teams.map((x) => (
                    <label key={x.key} className="flex items-center gap-2 text-body">
                      <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" checked={form.teamKeys.includes(x.key)}
                        onChange={(e) => setForm({ ...form, teamKeys: e.target.checked ? [...form.teamKeys, x.key] : form.teamKeys.filter((k) => k !== x.key) })} />
                      {x.name}
                    </label>
                  ))}
                </div>
              </fieldset>
            ) : null}

            {context.maySetSkills && groups.length > 0 ? (
              <fieldset className="flex flex-col gap-3">
                <legend className="mb-2 text-small font-semibold">{t.skills}</legend>
                <p className="text-caption text-p4a-grey">{t.skillsHint}</p>
                {groups.map((g) => (
                  <div key={g.dimension} className="grid grid-cols-2 gap-x-6 gap-y-2">
                    {g.skills.map((s) => {
                      const current = form.skills[s.key];
                      return s.levels.length > 0 ? (
                        <label key={s.key} className="flex items-center justify-between gap-3 text-body">
                          {s.name}
                          <select className={`${field} h-8 min-w-36`} value={typeof current === "number" ? String(current) : ""}
                            onChange={(e) => setSkill(s.key, e.target.value ? Number(e.target.value) : null)}>
                            <option value="">{t.levelNone}</option>
                            {s.levels.map((l) => <option key={l.level} value={l.level}>{l.name}</option>)}
                          </select>
                        </label>
                      ) : (
                        <label key={s.key} className="flex items-center gap-2 text-body">
                          <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" checked={current === true}
                            onChange={(e) => setSkill(s.key, e.target.checked ? true : null)} />
                          {s.name}
                        </label>
                      );
                    })}
                  </div>
                ))}
              </fieldset>
            ) : null}
          </div>
        )}

        {error ? <Notice tone="warning">{error}</Notice> : null}
        {armed ? <Notice tone="info">{t.unsaved}</Notice> : null}

        <footer className="flex items-center justify-end gap-3">
          {made ? (
            <Button variant="primary" onClick={close} data-testid="invite-done">{t.close}</Button>
          ) : (
            <>
              <Button variant="text" onClick={close} disabled={pending}>{t.cancel}</Button>
              <Button variant="primary" onClick={create} disabled={pending} data-testid="invite-create">
                {pending ? t.creating : t.create}
              </Button>
            </>
          )}
        </footer>
      </div>
    </dialog>
  );
}
