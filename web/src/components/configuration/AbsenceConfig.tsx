"use client";

/**
 * Absences and coverage: the absence types (add, edit, retire, reactivate) and the coverage
 * targets as a small grid per team: one row per work type, one cell per weekday, saved at once
 * when a cell is left or Enter is pressed (0 or empty clears). Keyboard: A adds an absence type,
 * T picks the team of the grid.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { AbsenceType, CoverageTargetRow, SkillInfo, TeamInfo } from "@/lib/data";
import { parseTarget, targetAt } from "@/lib/configuration";
import { Badge, Button, Keycap } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

type Form = { key: string; name: string; isPaid: boolean; sortOrder: number };

export function AbsenceConfig({ absences, teams, skills, targets, copy }: { absences: AbsenceType[]; teams: TeamInfo[]; skills: SkillInfo[]; targets: CoverageTargetRow[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configAbsences;
  const { state, save } = useSave(c);
  const [target, setTarget] = useState<{ absence: AbsenceType | null; opened: number } | null>(null);
  const [form, setForm] = useState<Form>({ key: "", name: "", isPaid: false, sortOrder: 100 });
  const [problem, setProblem] = useState<string | null>(null);
  const [team, setTeam] = useState(teams[0]?.key ?? "");
  const [cells, setCells] = useState<Record<string, string>>({});
  const workTypes = skills.filter((s) => s.dimension === "work_type" && s.isActive);
  const weekdays = t.weekdays.split(" ");

  function open(a: AbsenceType | null) {
    setForm(a ? { key: a.key, name: a.name, isPaid: a.isPaid, sortOrder: a.sortOrder } : { key: "", name: "", isPaid: false, sortOrder: 100 });
    setProblem(null);
    setTarget({ absence: a, opened: Date.now() });
  }

  async function submit() {
    if (!/^[a-z0-9_]+$/.test(form.key) || form.name.trim() === "") {
      setProblem(c.keyHint);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/absence-types", { ...form, name: form.name.trim() }))) setTarget(null);
  }

  async function saveCell(skillKey: string, weekday: number, text: string) {
    const n = parseTarget(text);
    const id = `${skillKey}:${weekday}`;
    if (n === null) {
      setCells({ ...cells, [id]: text });
      return;
    }
    if (n === targetAt(targets, team, skillKey, weekday)) return;
    await save(() => send("PUT", "/api/v1/configuration/coverage-targets", { teamKey: team, skillKey, weekday, minCount: n }));
    setCells((prev) => { const next = { ...prev }; delete next[id]; return next; });
  }

  const sorted = [...absences].sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.sortOrder - b.sortOrder);

  return (
    <div className="flex flex-col gap-8">
      <section>
        <div className="mb-4 flex items-end justify-between gap-4">
          <h2 className="text-panel font-semibold text-p4a-heading">{t.absenceTypes}</h2>
          <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => open(null)}>
            {c.add}
          </Button>
        </div>
        <SaveNote state={state} c={c} />
        <table className="w-full border-collapse text-body">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}>{c.name}</th>
              <th className={th}>{c.key}</th>
              <th className={th}>{t.paid}</th>
              <th className={`${th} text-right`}>{c.order}</th>
              <th className={th}>{c.active}</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((a) => (
              <tr key={a.key} className={a.isActive ? "" : "text-p4a-muted"}>
                <td className={`${td} font-semibold`}>{a.name}</td>
                <td className={`${td} text-small`}>{a.key}</td>
                <td className={td}>{a.isPaid ? t.paid : "—"}</td>
                <td className={`${td} text-right tabular-nums`}>{a.sortOrder}</td>
                <td className={td}>{a.isActive ? <Badge tone="success">{c.active}</Badge> : <Badge tone="neutral">{c.retired}</Badge>}</td>
                <td className={`${td} text-right`}>
                  <div className="flex justify-end gap-2">
                    <Button variant="outlined" size="sm" onClick={() => open(a)}>{c.edit}</Button>
                    {a.isActive ? (
                      <Button variant="destructive" size="sm" onClick={() => save(() => send("PUT", `/api/v1/configuration/absence-types/${a.key}/retired`))}>{c.retire}</Button>
                    ) : (
                      <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/absence-types", { key: a.key, name: a.name, isPaid: a.isPaid, sortOrder: a.sortOrder }))}>{c.reactivate}</Button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section>
        <h2 className="text-panel font-semibold text-p4a-heading">{t.targets}</h2>
        <p className="mb-4 mt-1 text-small text-p4a-muted">{t.targetsIntro}</p>
        {teams.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.noTeams}</p>
        ) : workTypes.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.noWorkTypes}</p>
        ) : (
          <>
            <label className={`${label} mb-4 max-w-sm`}>
              <span className="flex items-center gap-2">
                {copy.configTeams.team} <Keycap>T</Keycap>
              </span>
              <select className={field} value={team} data-shortcut="t" onChange={(e) => setTeam(e.target.value)}>
                {teams.map((x) => <option key={x.key} value={x.key}>{x.name}</option>)}
              </select>
            </label>
            <table className="border-collapse text-body">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{copy.configTeams.workType}</th>
                  {weekdays.map((d) => <th key={d} className={`${th} text-center`}>{d}</th>)}
                </tr>
              </thead>
              <tbody>
                {workTypes.map((s) => (
                  <tr key={s.key}>
                    <td className={`${td} font-semibold`}>{s.name}</td>
                    {weekdays.map((_, i) => {
                      const weekday = i + 1;
                      const id = `${s.key}:${weekday}`;
                      const value = cells[id] ?? String(targetAt(targets, team, s.key, weekday) || "");
                      return (
                        <td key={weekday} className={`${td} text-center`}>
                          <input
                            className={`${field} w-14 text-center tabular-nums`}
                            inputMode="numeric"
                            aria-label={`${s.name} ${weekdays[i]}`}
                            value={value}
                            onChange={(e) => setCells({ ...cells, [id]: e.target.value })}
                            onBlur={(e) => saveCell(s.key, weekday, e.target.value)}
                            onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
                          />
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </section>

      {target ? (
        <FormDialog key={target.opened} title={target.absence ? `${c.edit}: ${target.absence.name}` : `${c.add}: ${t.absenceTypes}`} onSave={submit} onClose={() => setTarget(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {c.key}
              <input className={field} value={form.key} disabled={target.absence !== null} onChange={(e) => setForm({ ...form, key: e.target.value })} />
              {target.absence ? null : <span className="font-normal text-caption text-p4a-muted">{c.keyHint}</span>}
            </label>
            <label className={label}>
              {c.name}
              <input className={field} value={form.name} maxLength={40} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </label>
            <label className={label}>
              {c.order}
              <input className={field} type="number" min={0} max={9999} value={form.sortOrder} onChange={(e) => setForm({ ...form, sortOrder: Number(e.target.value) })} />
            </label>
          </div>
          <FlagField name={t.paid} hint={t.paidHint} checked={form.isPaid} onChange={(v) => setForm({ ...form, isPaid: v })} />
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </div>
  );
}
