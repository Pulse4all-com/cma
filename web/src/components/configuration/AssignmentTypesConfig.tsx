"use client";

/**
 * Assignment types (Configuration → Roster, addition 0009zw, D2): the catalog a planner paints with (code, name, kind, the
 * status it books, extra hours, order, active) and the planner's settings (the grid, the lunch check, the planner zone).
 * A type's colour and Work area follow from the status it books (D13), so there is no colour to choose. Keyboard: I adds
 * an assignment type.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { AssignmentType, TenantSetting, WorkStatus } from "@/lib/data";
import { toneOf, TONE_CLASS } from "@/lib/assignments";
import { Badge, Button } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

type Form = { code: string; name: string; kind: "work" | "pause"; statusKey: string; isExtra: boolean; sortOrder: number; active: boolean };

const SLOT_CHOICES = ["5", "10", "15", "20", "30", "60"];

export function AssignmentTypesConfig({ types, statuses, settings, copy }: {
  types: AssignmentType[];
  /** The active work statuses a type may book */
  statuses: WorkStatus[];
  settings: TenantSetting[];
  copy: Pick<Copy, "configAssignments" | "configuration">;
}) {
  const c = copy.configuration;
  const t = copy.configAssignments;
  const { state, save } = useSave(c);
  const [target, setTarget] = useState<{ type: AssignmentType | null; opened: number } | null>(null);
  const [form, setForm] = useState<Form>({ code: "", name: "", kind: "work", statusKey: "", isExtra: false, sortOrder: 100, active: true });
  const [problem, setProblem] = useState<string | null>(null);
  const openings = useRef(0);
  const valueOf = (key: string) => settings.find((s) => s.key === key)?.value ?? "";
  const [lunchAfter, setLunchAfter] = useState<string | undefined>(undefined);
  const [zone, setZone] = useState<string | undefined>(undefined);
  const active = statuses;
  const fitting = active.filter((s) => (form.kind === "work") === s.isWorking);

  function open(x: AssignmentType | null) {
    setForm(x
      ? { code: x.code, name: x.name, kind: x.kind, statusKey: x.statusKey ?? "", isExtra: x.isExtra, sortOrder: x.sortOrder, active: x.isActive }
      : { code: "", name: "", kind: "work", statusKey: active.find((s) => s.isWorking)?.key ?? "", isExtra: false, sortOrder: 100, active: true });
    setProblem(null);
    openings.current += 1;
    setTarget({ type: x, opened: openings.current });
  }

  async function submit() {
    if (!/^[A-Z0-9]{1,6}$/.test(form.code) || form.name.trim() === "" || (!form.isExtra && !form.statusKey)) {
      setProblem(t.saveFailed);
      return;
    }
    const body = { ...form, name: form.name.trim(), statusKey: form.isExtra ? null : form.statusKey, kind: form.isExtra ? "work" : form.kind };
    if (await save(() => send("PUT", "/api/v1/configuration/assignment-types", body))) setTarget(null);
  }

  const setting = (key: string, value: string | null) => save(() => send("PUT", "/api/v1/configuration/settings", { key, value }));

  return (
    <div className="flex flex-col gap-8">
      <section data-testid="assignment-types">
        <div className="mb-4 flex items-end justify-between gap-4">
          <div>
            <h2 className="text-panel font-semibold text-p4a-heading">{t.title}</h2>
            <p className="mt-1 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
          </div>
          <Button variant="primary" shortcut="I" data-shortcut="i" onClick={() => open(null)}>{t.add}</Button>
        </div>
        <SaveNote state={state} c={c} />
        {types.length === 0 ? <p className="text-body text-p4a-muted">{t.noTypes}</p> : (
          <table className="w-full border-collapse text-body">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.code}</th>
                <th className={th}>{t.name}</th>
                <th className={th}>{t.kind}</th>
                <th className={th}>{t.status}</th>
                <th className={`${th} text-right`}>{t.order}</th>
                <th className={th}>{t.active}</th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {types.map((x) => (
                <tr key={x.code} className={x.isActive ? "" : "text-p4a-muted"}>
                  <td className={td}>
                    <span className={`inline-flex min-w-10 justify-center rounded-button px-2 py-0.5 text-small font-semibold ${TONE_CLASS[toneOf(x)]}`}>{x.code}</span>
                  </td>
                  <td className={`${td} font-semibold`}>{x.name}</td>
                  <td className={td}>{x.isExtra ? t.extra : x.kind === "work" ? t.kindWork : t.kindPause}</td>
                  <td className={td}>{x.statusName ?? "—"}</td>
                  <td className={`${td} text-right tabular-nums`}>{x.sortOrder}</td>
                  <td className={td}>{x.isActive ? <Badge tone="success">{t.active}</Badge> : <Badge tone="neutral">{t.retired}</Badge>}</td>
                  <td className={`${td} text-right`}><Button variant="outlined" size="sm" onClick={() => open(x)}>{c.edit}</Button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section data-testid="roster-settings">
        <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.planner}</h2>
        <div className="grid max-w-3xl grid-cols-2 gap-4">
          <label className={label}>
            {t.slotMinutes}
            <select className={field} value={valueOf("roster.slot_minutes") || "15"} onChange={(e) => setting("roster.slot_minutes", e.target.value)}>
              {SLOT_CHOICES.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
          </label>
          <label className={label}>
            {t.lunchAfter}
            <input className={`${field} tabular-nums`} inputMode="numeric" value={lunchAfter ?? valueOf("roster.lunch_after_minutes")}
              onChange={(e) => setLunchAfter(e.target.value)}
              onBlur={async () => { if (lunchAfter !== undefined && /^\d{1,4}$/.test(lunchAfter.trim())) { await setting("roster.lunch_after_minutes", lunchAfter.trim()); setLunchAfter(undefined); } }} />
          </label>
          <label className={label}>
            {t.lunchType}
            <select className={field} value={valueOf("roster.lunch_type_code")} onChange={(e) => setting("roster.lunch_type_code", e.target.value || null)}>
              <option value="">{t.lunchTypeAny}</option>
              {types.filter((x) => x.isActive && x.kind === "pause").map((x) => <option key={x.code} value={x.code}>{x.code} · {x.name}</option>)}
            </select>
          </label>
          <label className={label}>
            {t.plannerZone}
            <input className={field} value={zone ?? valueOf("roster.planner_timezone")}
              onChange={(e) => setZone(e.target.value)}
              onBlur={async () => { if (zone !== undefined) { await setting("roster.planner_timezone", zone.trim() || null); setZone(undefined); } }} />
            <span className="font-normal text-caption text-p4a-muted">{t.plannerZoneHint}</span>
          </label>
        </div>
      </section>

      {target ? (
        <FormDialog key={target.opened} title={target.type ? `${c.edit}: ${target.type.code}` : t.add} onSave={submit} onClose={() => setTarget(null)} busy={state.kind === "saving"} saveLabel={t.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.code}
              <input className={`${field} uppercase`} value={form.code} maxLength={6} disabled={target.type !== null} onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })} />
            </label>
            <label className={label}>
              {t.name}
              <input className={field} value={form.name} maxLength={40} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </label>
            <label className={label}>
              {t.kind}
              <select className={field} value={form.kind} disabled={form.isExtra}
                onChange={(e) => { const kind = e.target.value as Form["kind"]; setForm({ ...form, kind, statusKey: active.find((s) => (kind === "work") === s.isWorking)?.key ?? "" }); }}>
                <option value="work">{t.kindWork}</option>
                <option value="pause">{t.kindPause}</option>
              </select>
            </label>
            <label className={label}>
              {t.status}
              <select className={field} value={form.isExtra ? "" : form.statusKey} disabled={form.isExtra} onChange={(e) => setForm({ ...form, statusKey: e.target.value })}>
                {form.isExtra ? <option value="">—</option> : null}
                {fitting.map((s) => <option key={s.key} value={s.key}>{s.name}</option>)}
              </select>
            </label>
            <label className={label}>
              {t.order}
              <input className={field} type="number" min={0} max={9999} value={form.sortOrder} onChange={(e) => setForm({ ...form, sortOrder: Number(e.target.value) })} />
            </label>
          </div>
          <FlagField name={t.extra} checked={form.isExtra} onChange={(v) => setForm({ ...form, isExtra: v, kind: v ? "work" : form.kind })} />
          <FlagField name={t.active} checked={form.active} onChange={(v) => setForm({ ...form, active: v })} />
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </div>
  );
}
