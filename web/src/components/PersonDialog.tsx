"use client";

/**
 * Edit person and Add a person: one native <dialog>, mounted per opening (the parent gives it a
 * key), so every opening starts from the person as they stand now.
 *
 * Edit sends the smallest set of writes (lib/team editChanges): the role, the active flag, the
 * full team list, the full skill list, each only when it changed, through the directory routes;
 * the database decides again what the caller may change (403 → a clear message). Add sends one
 * request that writes user, login id and role in one statement, so a refusal writes nothing. No
 * role, team or skill key is known here: the lists come from the tenant's catalogs.
 *
 * Keyboard: Tab through the fields, Ctrl+Enter saves, Esc closes (twice with unsaved changes).
 */
import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import type { Copy } from "@/lib/copy";
import type { DirectoryPerson, OrganisationInfo, RoleInfo, SkillInfo, TeamInfo } from "@/lib/data";
import {
  checkNewPerson, editChanges, hasChanges, roleOptions, skillStateOf, skillsByDimension,
  type EditState, type NewPersonForm, type NewPersonProblem, type SkillState,
} from "@/lib/team";
import { Button, Notice } from "./primitives";

export type PersonDialogTarget = { mode: "edit"; person: DirectoryPerson } | { mode: "add" };

const field = "h-10 rounded-input border border-p4a-border bg-white px-3 text-body text-p4a-body focus:border-p4a-deepblue";
const label = "flex flex-col gap-2 text-small font-semibold text-p4a-body";

async function send(method: "PUT" | "POST", path: string, body: unknown): Promise<Response> {
  return fetch(path, {
    method,
    headers: { "content-type": "application/json", "x-cma-request": "1" },
    body: JSON.stringify(body),
  });
}

export function PersonDialog({
  target,
  roles,
  teams,
  skills,
  organisations,
  maySetSkills,
  defaultLoginSystem,
  copy,
  onClose,
  onSaved,
}: {
  target: PersonDialogTarget;
  roles: RoleInfo[];
  teams: TeamInfo[];
  skills: SkillInfo[];
  organisations: OrganisationInfo[];
  maySetSkills: boolean;
  defaultLoginSystem: string;
  copy: Copy;
  onClose: () => void;
  onSaved: () => void;
}) {
  const t = copy.team;
  const ref = useRef<HTMLDialogElement>(null);
  const [pending, startTransition] = useTransition();
  const [armed, setArmed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [problems, setProblems] = useState<NewPersonProblem[]>([]);

  const person = target.mode === "edit" ? target.person : null;
  const initial: EditState = useMemo(
    () => ({
      roleKey: person?.roleKey ?? null,
      active: person?.isActive ?? true,
      teams: person?.teams.map((x) => x.key) ?? [],
      skills: skillStateOf(person?.skills ?? []),
    }),
    [person],
  );
  const [edit, setEdit] = useState<EditState>(initial);
  const emptyForm: NewPersonForm = useMemo(() => ({
    displayName: "",
    email: "",
    organisationKey: organisations.length === 1 ? organisations[0]!.key : "",
    roleKey: "",
    loginSystem: defaultLoginSystem,
    loginId: "",
    timeZone: "",
  }), [organisations, defaultLoginSystem]);
  const [form, setForm] = useState<NewPersonForm>(emptyForm);

  const groups = useMemo(() => skillsByDimension(skills), [skills]);
  const changes = useMemo(() => editChanges(initial, edit, skills), [initial, edit, skills]);
  const dirty = target.mode === "edit" ? hasChanges(changes) : JSON.stringify(form) !== JSON.stringify(emptyForm);

  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
  }, []);

  function close() {
    if (dirty && !armed) {
      setArmed(true);
      return;
    }
    onClose();
  }

  function messageFor(status: number): string {
    if (status === 403) return t.notPermitted;
    if (status === 404) return t.notFound;
    if (status === 409) return t.conflict;
    return t.saveFailed;
  }

  function save() {
    setError(null);
    if (target.mode === "add") {
      const found = checkNewPerson(form);
      setProblems(found);
      if (found.length > 0) return;
      startTransition(async () => {
        const res = await send("POST", "/api/v1/team/directory", {
          email: form.email.trim(),
          displayName: form.displayName.trim(),
          organisationKey: form.organisationKey,
          roleKey: form.roleKey,
          loginSystem: form.loginSystem.trim(),
          loginId: form.loginId.trim(),
          timeZone: form.timeZone.trim() || null,
        });
        if (!res.ok) {
          setError(messageFor(res.status));
          return;
        }
        onSaved();
      });
      return;
    }
    if (!person) return;
    if (!hasChanges(changes)) {
      setError(t.problemNoChange);
      return;
    }
    startTransition(async () => {
      const base = `/api/v1/team/directory/${person.userId}`;
      const steps: [string, unknown][] = [];
      if (changes.roleKey) steps.push([`${base}/role`, { roleKey: changes.roleKey }]);
      if (changes.teams) steps.push([`${base}/teams`, { teamKeys: changes.teams }]);
      if (changes.skills) steps.push([`${base}/skills`, { skills: changes.skills }]);
      // The active flag last: deactivating first would make the other writes pointless
      if (changes.active !== undefined) steps.push([`${base}/active`, { active: changes.active }]);
      for (const [path, body] of steps) {
        const res = await send("PUT", path, body);
        if (!res.ok) {
          setError(messageFor(res.status));
          return;
        }
      }
      onSaved();
    });
  }

  function setSkill(key: string, value: number | true | null) {
    setEdit((s) => {
      const next: SkillState = { ...s.skills };
      if (value === null) delete next[key];
      else next[key] = value;
      return { ...s, skills: next };
    });
  }

  const roleChoices = roleOptions(roles, person?.roleKey ?? null);

  return (
    <dialog
      ref={ref}
      className="m-auto w-[44rem] max-w-[calc(100vw-4rem)] rounded-card border border-p4a-border bg-white p-0 text-p4a-body backdrop:bg-p4a-inkt/40"
      onCancel={(e) => {
        e.preventDefault();
        close();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          save();
        }
        if (e.key !== "Escape") setArmed(false);
      }}
    >
      <div className="flex flex-col gap-6 p-6">
        <header>
          <h2 className="text-panel font-semibold text-p4a-heading">{target.mode === "add" ? t.addTitle : t.editTitle}</h2>
          {target.mode === "add" ? (
            <p className="mt-1 text-small text-p4a-muted">{t.addIntro}</p>
          ) : (
            <p className="mt-1 text-small text-p4a-muted">
              {person?.displayName} · {person?.email} · {person?.organisationName}
            </p>
          )}
        </header>

        {target.mode === "add" ? (
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.name}
              <input className={field} value={form.displayName} autoFocus maxLength={100} onChange={(e) => setForm({ ...form, displayName: e.target.value })} />
              {problems.includes("name") ? <span className="text-caption font-normal text-p4a-error">{t.problemName}</span> : null}
            </label>
            <label className={label}>
              {t.email}
              <input className={field} type="email" value={form.email} maxLength={200} onChange={(e) => setForm({ ...form, email: e.target.value })} />
              {problems.includes("email") ? <span className="text-caption font-normal text-p4a-error">{t.problemEmail}</span> : null}
            </label>
            <label className={label}>
              {t.employer}
              <select className={field} value={form.organisationKey} onChange={(e) => setForm({ ...form, organisationKey: e.target.value })}>
                <option value="">{t.chooseEmployer}</option>
                {organisations.map((o) => (
                  <option key={o.key} value={o.key}>{o.name}</option>
                ))}
              </select>
              {problems.includes("employer") ? <span className="text-caption font-normal text-p4a-error">{t.problemEmployer}</span> : null}
            </label>
            <label className={label}>
              {t.role}
              <select className={field} value={form.roleKey} onChange={(e) => setForm({ ...form, roleKey: e.target.value })}>
                <option value="">{t.chooseRole}</option>
                {roles.filter((r) => r.assignable).map((r) => (
                  <option key={r.key} value={r.key}>{r.name}</option>
                ))}
              </select>
              <span className="text-caption font-normal text-p4a-grey">{t.roleHint}</span>
              {problems.includes("role") ? <span className="text-caption font-normal text-p4a-error">{t.problemRole}</span> : null}
            </label>
            <label className={label}>
              {t.loginSystem}
              <input className={field} value={form.loginSystem} maxLength={40} onChange={(e) => setForm({ ...form, loginSystem: e.target.value })} />
            </label>
            <label className={label}>
              {t.loginId}
              <input className={`${field} tabular`} value={form.loginId} maxLength={200} autoComplete="off" onChange={(e) => setForm({ ...form, loginId: e.target.value })} />
              <span className="text-caption font-normal text-p4a-grey">{t.loginIdHint}</span>
              {problems.includes("login") ? <span className="text-caption font-normal text-p4a-error">{t.problemLogin}</span> : null}
            </label>
            <label className={label}>
              {t.timeZone}
              <input className={field} value={form.timeZone} maxLength={60} placeholder={t.timeZoneHint} onChange={(e) => setForm({ ...form, timeZone: e.target.value })} />
            </label>
          </div>
        ) : (
          <div className="flex flex-col gap-6">
            <div className="grid grid-cols-2 gap-4">
              <label className={label}>
                {t.role}
                <select className={field} value={edit.roleKey ?? ""} autoFocus onChange={(e) => setEdit({ ...edit, roleKey: e.target.value || null })}>
                  {!edit.roleKey ? <option value="">{t.noRole}</option> : null}
                  {roleChoices.map((r) => (
                    <option key={r.key} value={r.key} disabled={r.disabled}>{r.name}</option>
                  ))}
                </select>
                <span className="text-caption font-normal text-p4a-grey">{t.roleHint}</span>
              </label>
              <label className="flex items-start gap-3 pt-7 text-body">
                <input type="checkbox" className="mt-1 h-4 w-4 accent-p4a-deepblue" checked={edit.active} onChange={(e) => setEdit({ ...edit, active: e.target.checked })} />
                <span>
                  <span className="font-semibold">{t.active}</span>
                  <span className="block text-caption text-p4a-grey">{t.activeHint}</span>
                </span>
              </label>
            </div>

            <fieldset className="flex flex-col gap-2">
              <legend className="mb-2 text-small font-semibold">{t.teams}</legend>
              {teams.length === 0 ? (
                <p className="text-small text-p4a-muted">{t.noTeams}</p>
              ) : (
                <div className="grid grid-cols-3 gap-2">
                  {teams.map((x) => (
                    <label key={x.key} className="flex items-center gap-2 text-body">
                      <input
                        type="checkbox"
                        className="h-4 w-4 accent-p4a-deepblue"
                        checked={edit.teams.includes(x.key)}
                        onChange={(e) => setEdit({ ...edit, teams: e.target.checked ? [...edit.teams, x.key] : edit.teams.filter((k) => k !== x.key) })}
                      />
                      {x.name}
                    </label>
                  ))}
                </div>
              )}
            </fieldset>

            <fieldset className="flex flex-col gap-3">
              <legend className="mb-2 text-small font-semibold">{t.skills}</legend>
              <p className="text-caption text-p4a-grey">{maySetSkills ? t.skillsHint : t.skillsNotPermitted}</p>
              {groups.map((g) => (
                <div key={g.dimension} className="grid grid-cols-2 gap-x-6 gap-y-2">
                  {g.skills.map((s) => {
                    const current = edit.skills[s.key];
                    return s.levels.length > 0 ? (
                      <label key={s.key} className="flex items-center justify-between gap-3 text-body">
                        {s.name}
                        <select
                          className={`${field} h-8 min-w-36`}
                          disabled={!maySetSkills}
                          value={typeof current === "number" ? String(current) : ""}
                          onChange={(e) => setSkill(s.key, e.target.value ? Number(e.target.value) : null)}
                        >
                          <option value="">{t.levelNone}</option>
                          {s.levels.map((l) => (
                            <option key={l.level} value={l.level}>{l.name}</option>
                          ))}
                        </select>
                      </label>
                    ) : (
                      <label key={s.key} className="flex items-center gap-2 text-body">
                        <input
                          type="checkbox"
                          className="h-4 w-4 accent-p4a-deepblue"
                          disabled={!maySetSkills}
                          checked={current === true}
                          onChange={(e) => setSkill(s.key, e.target.checked ? true : null)}
                        />
                        {s.name}
                      </label>
                    );
                  })}
                </div>
              ))}
            </fieldset>
          </div>
        )}

        {error ? <Notice tone="warning">{error}</Notice> : null}
        {armed ? <Notice tone="info">{t.unsaved}</Notice> : null}

        <footer className="flex items-center justify-end gap-3">
          <Button variant="text" onClick={close} disabled={pending}>
            {t.cancel}
          </Button>
          <Button variant="primary" onClick={save} disabled={pending} data-testid="person-save">
            {pending ? t.saving : t.save}
          </Button>
        </footer>
      </div>
    </dialog>
  );
}
