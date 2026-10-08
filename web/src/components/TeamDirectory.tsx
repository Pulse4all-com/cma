"use client";

/**
 * The People table and its dialogs. Rows come from the server (cma.directory); editing happens
 * in a native <dialog> mounted per opening, so every edit starts from the person as they stand.
 * After a save the page re-reads itself (router.refresh), so the table always shows the
 * database's answer and never a guess.
 *
 * Keyboard: Down or Up enters the table, the arrows move between rows, Enter opens the row's
 * editor, A adds a person, I shows or hides inactive people, T filters by team, Esc closes.
 */
import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { DirectoryPerson, OrganisationInfo, RoleInfo, SkillInfo, TeamInfo } from "@/lib/data";
import { filterPeople, skillLabel } from "@/lib/team";
import { PersonDialog, type PersonDialogTarget } from "./PersonDialog";
import { Badge, Button, Keycap } from "./primitives";

export function TeamDirectory({
  people,
  roles,
  teams,
  skills,
  organisations,
  meId,
  maySetSkills,
  defaultLoginSystem,
  copy,
}: {
  people: DirectoryPerson[];
  roles: RoleInfo[];
  teams: TeamInfo[];
  skills: SkillInfo[];
  organisations: OrganisationInfo[];
  meId: string;
  /** skills.manage: without it the editor shows skills read-only */
  maySetSkills: boolean;
  defaultLoginSystem: string;
  copy: Copy;
}) {
  const t = copy.team;
  const router = useRouter();
  const [showInactive, setShowInactive] = useState(false);
  const [team, setTeam] = useState("");
  const [target, setTarget] = useState<PersonDialogTarget | null>(null);
  const [opened, setOpened] = useState(0);
  const body = useRef<HTMLTableSectionElement>(null);
  const opener = useRef<HTMLElement | null>(null);

  // Down or Up outside the table (not while typing, not in a dialog) enters it, like the other tables
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.key !== "ArrowDown" && e.key !== "ArrowUp") || e.ctrlKey || e.metaKey || e.altKey) return;
      if (document.querySelector("dialog[open]")) return;
      const active = document.activeElement as HTMLElement | null;
      if (active && (["INPUT", "SELECT", "TEXTAREA"].includes(active.tagName) || active.isContentEditable)) return;
      const tbody = body.current;
      if (!tbody || (active && tbody.contains(active))) return;
      const buttons = Array.from(tbody.querySelectorAll<HTMLButtonElement>("button:not([disabled])"));
      const first = e.key === "ArrowDown" ? buttons[0] : buttons[buttons.length - 1];
      if (!first) return;
      e.preventDefault();
      first.focus();
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);

  function open(next: PersonDialogTarget) {
    opener.current = document.activeElement as HTMLElement | null;
    setOpened((n) => n + 1);
    setTarget(next);
  }

  function close() {
    setTarget(null);
    requestAnimationFrame(() => opener.current?.focus());
  }

  function move(e: ReactKeyboardEvent<HTMLTableSectionElement>) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    const buttons = Array.from(e.currentTarget.querySelectorAll<HTMLButtonElement>("button:not([disabled])"));
    const i = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (i < 0) return;
    e.preventDefault();
    buttons[e.key === "ArrowDown" ? Math.min(buttons.length - 1, i + 1) : Math.max(0, i - 1)]?.focus();
  }

  const rows = filterPeople(people, { showInactive, team });
  const th = "h-10 whitespace-nowrap px-3 text-left font-semibold";

  return (
    <>
      <div className="mb-4 flex items-end justify-between gap-4">
        <div className="flex items-end gap-4">
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">
              {t.teamFilter} <Keycap>T</Keycap>
            </span>
            <select
              value={team}
              data-shortcut="t"
              onChange={(e) => setTeam(e.target.value)}
              className="h-10 min-w-56 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
            >
              <option value="">{t.allTeams}</option>
              {teams.map((x) => (
                <option key={x.key} value={x.key}>
                  {x.name} ({x.memberCount})
                </option>
              ))}
            </select>
          </label>
          <Button variant="outlined" shortcut="I" data-shortcut="i" onClick={() => setShowInactive((v) => !v)} aria-pressed={showInactive}>
            {showInactive ? t.hideInactive : t.showInactive}
          </Button>
        </div>
        <div className="flex items-end gap-4">
          <span className="pb-2 text-caption text-p4a-grey">
            {t.peopleShown.replace("{n}", String(rows.length)).replace("{total}", String(people.length))}
          </span>
          <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => open({ mode: "add" })}>
            {t.add}
          </Button>
        </div>
      </div>

      {rows.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        <table className="w-full border-collapse text-body">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}>{t.person}</th>
              <th className={th}>{t.employer}</th>
              <th className={th}>{t.role}</th>
              <th className={th}>{t.teams}</th>
              <th className={th}>{t.skills}</th>
              <th className={th}>{t.status}</th>
              <th className={th}>
                <span className="sr-only">{t.edit}</span>
              </th>
            </tr>
          </thead>
          <tbody ref={body} onKeyDown={move}>
            {rows.map((p) => (
              <tr key={p.userId} data-testid="person-row" className="border-b border-p4a-border odd:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                <td className="px-3 py-2 align-top">
                  <div className="font-semibold">{p.displayName}</div>
                  <div className="text-caption text-p4a-grey">{p.email}</div>
                </td>
                <td className="px-3 py-2 align-top">{p.organisationName}</td>
                <td className="px-3 py-2 align-top">
                  {p.roleName ?? <span className="text-p4a-muted">{t.noRole}</span>}
                  {p.isManaging ? <div className="text-caption text-p4a-grey">{t.managing}</div> : null}
                </td>
                <td className="px-3 py-2 align-top">
                  {p.teams.length === 0 ? (
                    <span className="text-p4a-muted">{t.noTeams}</span>
                  ) : (
                    <div className="flex flex-wrap gap-1">
                      {p.teams.map((x) => (
                        <Badge key={x.key} tone="info">{x.name}</Badge>
                      ))}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 align-top">
                  {p.skills.length === 0 ? (
                    <span className="text-p4a-muted">{t.noSkills}</span>
                  ) : (
                    <div className="flex flex-wrap gap-1">
                      {p.skills.map((s) => (
                        <Badge key={s.key} tone="neutral">{skillLabel(s)}</Badge>
                      ))}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 align-top">
                  <div className="flex flex-wrap gap-1">
                    <Badge tone={p.isActive ? "success" : "neutral"}>{p.isActive ? t.active : t.inactive}</Badge>
                    {p.isActive ? <Badge tone={p.timeKept ? "info" : "neutral"}>{p.timeKept ? t.clockKept : t.noClock}</Badge> : null}
                  </div>
                </td>
                <td className="px-3 py-2 align-top text-right">
                  <Button
                    variant="outlined"
                    size="sm"
                    disabled={!p.mayEdit}
                    title={p.userId === meId ? t.self : p.mayEdit ? undefined : t.notEditable}
                    onClick={() => open({ mode: "edit", person: p })}
                  >
                    {t.edit}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {target ? (
        <PersonDialog
          key={opened}
          target={target}
          roles={roles}
          teams={teams}
          skills={skills}
          organisations={organisations}
          maySetSkills={maySetSkills}
          defaultLoginSystem={defaultLoginSystem}
          copy={copy}
          onClose={close}
          onSaved={() => {
            close();
            router.refresh();
          }}
        />
      ) : null}
    </>
  );
}
