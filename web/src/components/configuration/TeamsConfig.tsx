"use client";

/**
 * Teams and skills: the current teams (add, edit, dissolve) and the skill catalog per dimension
 * with its level scale (add, retire, reactivate, the scale's names). The database keeps the
 * history (a dissolved team's memberships end, a retired skill stays on the people who hold it)
 * and refuses a scale that drops a level someone holds (409). Keyboard: A adds a team, K a skill.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { SkillDimension, SkillInfo, TeamInfo } from "@/lib/data";
import { levelsText, parseLevels, parseMarkets } from "@/lib/configuration";
import { ConfirmDialog } from "../ConfirmDialog";
import { Badge, Button } from "../primitives";
import { FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

const DIMENSIONS: SkillDimension[] = ["language", "work_type", "channel"];

type TeamForm = { key: string; name: string; markets: string; sortOrder: number };
type SkillForm = { dimension: SkillDimension; key: string; name: string; sortOrder: number };

export function TeamsConfig({ teams, skills, copy }: { teams: TeamInfo[]; skills: SkillInfo[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configTeams;
  const { state, save } = useSave(c);
  const [teamTarget, setTeamTarget] = useState<{ team: TeamInfo | null; opened: number } | null>(null);
  const [teamForm, setTeamForm] = useState<TeamForm>({ key: "", name: "", markets: "", sortOrder: 100 });
  const [dissolving, setDissolving] = useState<TeamInfo | null>(null);
  const [skillTarget, setSkillTarget] = useState<{ skill: SkillInfo | null; opened: number } | null>(null);
  const [skillForm, setSkillForm] = useState<SkillForm>({ dimension: "language", key: "", name: "", sortOrder: 100 });
  const [scale, setScale] = useState<{ dimension: SkillDimension; text: string; opened: number } | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [showRetired, setShowRetired] = useState(false);

  const dimensionLabel: Record<SkillDimension, string> = { language: t.language, work_type: t.workType, channel: t.channel };

  function openTeam(team: TeamInfo | null) {
    setTeamForm(team ? { key: team.key, name: team.name, markets: team.markets.join(" "), sortOrder: team.sortOrder } : { key: "", name: "", markets: "", sortOrder: 100 });
    setProblem(null);
    setTeamTarget({ team, opened: Date.now() });
  }

  async function saveTeam() {
    const markets = parseMarkets(teamForm.markets);
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(teamForm.key) || teamForm.name.trim() === "" || markets === null) {
      setProblem(markets === null ? t.marketsHint : c.keyHint);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/teams", { key: teamForm.key, name: teamForm.name.trim(), markets, sortOrder: teamForm.sortOrder }))) setTeamTarget(null);
  }

  function openSkill(skill: SkillInfo | null, dimension: SkillDimension) {
    setSkillForm(skill ? { dimension: skill.dimension, key: skill.key, name: skill.name, sortOrder: skill.sortOrder } : { dimension, key: "", name: "", sortOrder: 100 });
    setProblem(null);
    setSkillTarget({ skill, opened: Date.now() });
  }

  async function saveSkill(active = true) {
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(skillForm.key) || skillForm.name.trim() === "") {
      setProblem(c.keyHint);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/skills", { ...skillForm, name: skillForm.name.trim(), active }))) setSkillTarget(null);
  }

  async function saveScale() {
    if (!scale) return;
    const levels = parseLevels(scale.text);
    if (levels === null) {
      setProblem(t.scaleHint);
      return;
    }
    if (await save(() => send("PUT", `/api/v1/configuration/skills/${scale.dimension}/levels`, { levels }), t.scaleInUse)) setScale(null);
  }

  return (
    <div className="flex flex-col gap-8">
      <section>
        <div className="mb-4 flex items-end justify-between gap-4">
          <h2 className="text-panel font-semibold text-p4a-heading">{copy.nav.team}</h2>
          <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => openTeam(null)}>
            {c.add}
          </Button>
        </div>
        <SaveNote state={state} c={c} />
        {teams.length === 0 ? (
          <p className="text-body text-p4a-muted">{t.emptyDimension}</p>
        ) : (
          <table className="w-full border-collapse text-body">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.team}</th>
                <th className={th}>{c.key}</th>
                <th className={th}>{t.markets}</th>
                <th className={`${th} text-right`}>{t.members}</th>
                <th className={`${th} text-right`}>{c.order}</th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {teams.map((x) => (
                <tr key={x.key}>
                  <td className={`${td} font-semibold`}>{x.name}</td>
                  <td className={`${td} text-small`}>{x.key}</td>
                  <td className={`${td} text-small uppercase`}>{x.markets.join(" ")}</td>
                  <td className={`${td} text-right tabular-nums`}>{x.memberCount}</td>
                  <td className={`${td} text-right tabular-nums`}>{x.sortOrder}</td>
                  <td className={`${td} text-right`}>
                    <div className="flex justify-end gap-2">
                      <Button variant="outlined" size="sm" onClick={() => openTeam(x)}>{c.edit}</Button>
                      <Button variant="destructive" size="sm" onClick={() => setDissolving(x)}>{t.dissolve}</Button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section>
        <div className="mb-4 flex items-end justify-between gap-4">
          <h2 className="text-panel font-semibold text-p4a-heading">{t.skills}</h2>
          <div className="flex gap-3">
            <Button variant="outlined" shortcut="R" data-shortcut="r" onClick={() => setShowRetired((v) => !v)} aria-pressed={showRetired}>
              {showRetired ? c.hideRetired : c.showRetired}
            </Button>
            <Button variant="primary" shortcut="K" data-shortcut="k" onClick={() => openSkill(null, "language")}>
              {c.add}
            </Button>
          </div>
        </div>
        <div className="grid grid-cols-3 gap-6">
          {DIMENSIONS.map((d) => {
            const list = skills.filter((s) => s.dimension === d && (showRetired || s.isActive)).sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.sortOrder - b.sortOrder);
            const levels = skills.find((s) => s.dimension === d)?.levels ?? [];
            return (
              <div key={d} className="rounded-card border border-p4a-border p-4">
                <h3 className="text-body font-semibold text-p4a-heading">{dimensionLabel[d]}</h3>
                <p className="mb-3 mt-1 text-caption text-p4a-muted">
                  {t.scale}: {levels.length === 0 ? t.binary : levelsText(levels)}
                  {" · "}
                  <button type="button" className="text-p4a-deepblue hover:underline" onClick={() => { setProblem(null); setScale({ dimension: d, text: levelsText(levels), opened: Date.now() }); }}>
                    {c.edit}
                  </button>
                </p>
                {list.length === 0 ? (
                  <p className="text-small text-p4a-muted">{t.emptyDimension}</p>
                ) : (
                  <ul className="flex flex-col gap-1">
                    {list.map((s) => (
                      <li key={s.key} className={`flex items-center justify-between gap-2 text-small ${s.isActive ? "" : "text-p4a-muted"}`}>
                        <span>
                          {s.name} <span className="text-p4a-muted">({s.key})</span>
                          {s.isActive ? null : <span className="ml-2"><Badge tone="neutral">{c.retired}</Badge></span>}
                        </span>
                        <span className="flex gap-1">
                          <Button variant="text" size="sm" onClick={() => openSkill(s, d)}>{c.edit}</Button>
                          {s.isActive ? (
                            <Button variant="text" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/skills", { dimension: d, key: s.key, name: s.name, sortOrder: s.sortOrder, active: false }))}>{c.retire}</Button>
                          ) : (
                            <Button variant="text" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/skills", { dimension: d, key: s.key, name: s.name, sortOrder: s.sortOrder, active: true }))}>{c.reactivate}</Button>
                          )}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            );
          })}
        </div>
      </section>

      {teamTarget ? (
        <FormDialog key={teamTarget.opened} title={teamTarget.team ? `${c.edit}: ${teamTarget.team.name}` : `${c.add}: ${t.team}`} onSave={saveTeam} onClose={() => setTeamTarget(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {c.key}
              <input className={field} value={teamForm.key} disabled={teamTarget.team !== null} onChange={(e) => setTeamForm({ ...teamForm, key: e.target.value })} />
            </label>
            <label className={label}>
              {c.name}
              <input className={field} value={teamForm.name} maxLength={60} onChange={(e) => setTeamForm({ ...teamForm, name: e.target.value })} />
            </label>
            <label className={label}>
              {t.markets}
              <input className={field} value={teamForm.markets} onChange={(e) => setTeamForm({ ...teamForm, markets: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.marketsHint}</span>
            </label>
            <label className={label}>
              {c.order}
              <input className={field} type="number" min={0} max={9999} value={teamForm.sortOrder} onChange={(e) => setTeamForm({ ...teamForm, sortOrder: Number(e.target.value) })} />
            </label>
          </div>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {skillTarget ? (
        <FormDialog key={skillTarget.opened} title={skillTarget.skill ? `${c.edit}: ${skillTarget.skill.name}` : `${c.add}: ${t.skills}`} onSave={() => saveSkill(true)} onClose={() => setSkillTarget(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.dimension}
              <select className={field} value={skillForm.dimension} disabled={skillTarget.skill !== null} onChange={(e) => setSkillForm({ ...skillForm, dimension: e.target.value as SkillDimension })}>
                {DIMENSIONS.map((d) => <option key={d} value={d}>{dimensionLabel[d]}</option>)}
              </select>
            </label>
            <label className={label}>
              {c.key}
              <input className={field} value={skillForm.key} disabled={skillTarget.skill !== null} onChange={(e) => setSkillForm({ ...skillForm, key: e.target.value })} />
            </label>
            <label className={label}>
              {c.name}
              <input className={field} value={skillForm.name} maxLength={40} onChange={(e) => setSkillForm({ ...skillForm, name: e.target.value })} />
            </label>
            <label className={label}>
              {c.order}
              <input className={field} type="number" min={0} max={9999} value={skillForm.sortOrder} onChange={(e) => setSkillForm({ ...skillForm, sortOrder: Number(e.target.value) })} />
            </label>
          </div>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {scale ? (
        <FormDialog key={scale.opened} title={`${t.scale}: ${dimensionLabel[scale.dimension]}`} intro={t.scaleHint} onSave={saveScale} onClose={() => setScale(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.levels}
            <input className={field} value={scale.text} onChange={(e) => setScale({ ...scale, text: e.target.value })} />
          </label>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      <ConfirmDialog
        open={dissolving !== null}
        title={t.dissolve}
        confirmLabel={t.dissolve}
        cancelLabel={c.cancel}
        busy={state.kind === "saving"}
        onCancel={() => setDissolving(null)}
        onConfirm={async () => {
          if (!dissolving) return;
          if (await save(() => send("PUT", `/api/v1/configuration/teams/${dissolving.key}/dissolved`))) setDissolving(null);
        }}
      >
        {t.dissolveConfirm.replace("{name}", dissolving?.name ?? "")}
      </ConfirmDialog>
    </div>
  );
}
