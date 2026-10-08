"use client";

/**
 * Statuses: the tenant's work_status list with its four flags, the default, retire and
 * reactivate. Every write goes through /api/v1/configuration/statuses; the database applies the
 * rules (frozen flags on a status with time behind it, one working default, never the last
 * working status) and the form explains them first (lib/configuration). Keyboard: A adds, R
 * shows or hides retired statuses, Ctrl+Enter saves in the dialog, Esc closes.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { ConfigStatus } from "@/lib/data";
import { flagsFrozen, retireProblem, statusFormProblem, visibleStatuses } from "@/lib/configuration";
import { Badge, Button } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

type Form = { key: string; name: string; isWorking: boolean; isProductive: boolean; isPaid: boolean; isBillable: boolean; sortOrder: number };

function formOf(s: ConfigStatus | null): Form {
  return s
    ? { key: s.key, name: s.name, isWorking: s.isWorking, isProductive: s.isProductive, isPaid: s.isPaid, isBillable: s.isBillable, sortOrder: s.sortOrder }
    : { key: "", name: "", isWorking: true, isProductive: true, isPaid: true, isBillable: true, sortOrder: 100 };
}

export function StatusConfig({ statuses, copy }: { statuses: ConfigStatus[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configStatuses;
  const [showRetired, setShowRetired] = useState(false);
  const [target, setTarget] = useState<{ status: ConfigStatus | null; opened: number } | null>(null);
  const [form, setForm] = useState<Form>(formOf(null));
  const [problem, setProblem] = useState<string | null>(null);
  const { state, save } = useSave(c);
  const rows = visibleStatuses(statuses, showRetired);
  const editing = target?.status ?? null;
  const frozen = editing ? flagsFrozen(editing) : false;

  function open(s: ConfigStatus | null) {
    setForm(formOf(s));
    setProblem(null);
    setTarget({ status: s, opened: Date.now() });
  }

  async function submit() {
    const p = statusFormProblem(form, editing === null, statuses.map((s) => s.key));
    if (p) {
      setProblem(p === "name" ? c.invalid : c.keyHint);
      return;
    }
    const conflict = editing?.isDefault && !form.isWorking ? t.defaultMustWork : t.flagsFrozen;
    if (await save(() => send("PUT", "/api/v1/configuration/statuses", form), conflict)) setTarget(null);
  }

  const flags = (s: ConfigStatus) =>
    [s.isWorking && t.working, s.isProductive && t.productive, s.isPaid && t.paid, s.isBillable && t.billable].filter(Boolean).join(" · ") || "—";

  return (
    <>
      <div className="mb-4 flex items-end justify-between gap-4">
        <Button variant="outlined" shortcut="R" data-shortcut="r" onClick={() => setShowRetired((v) => !v)} aria-pressed={showRetired}>
          {showRetired ? c.hideRetired : c.showRetired}
        </Button>
        <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => open(null)}>
          {c.add}
        </Button>
      </div>
      <div className="mb-4">
        <SaveNote state={state} c={c} />
      </div>

      {rows.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        <table className="w-full border-collapse text-body">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}>{t.status}</th>
              <th className={th}>{c.key}</th>
              <th className={th}>{t.flags}</th>
              <th className={`${th} text-right`}>{c.order}</th>
              <th className={`${th} text-right`}>{t.usage}</th>
              <th className={th}>{c.active}</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((s) => {
              const why = retireProblem(s, statuses);
              return (
                <tr key={s.key} className={s.isActive ? "" : "text-p4a-muted"}>
                  <td className={td}>
                    <span className="font-semibold">{s.name}</span>
                    {s.isDefault ? <span className="ml-2"><Badge tone="info">{t.isDefault}</Badge></span> : null}
                  </td>
                  <td className={`${td} text-small`}>{s.key}</td>
                  <td className={`${td} text-small`}>{flags(s)}</td>
                  <td className={`${td} text-right tabular-nums`}>{s.sortOrder}</td>
                  <td className={`${td} text-right tabular-nums`}>{s.usageCount}</td>
                  <td className={td}>{s.isActive ? <Badge tone="success">{c.active}</Badge> : <Badge tone="neutral">{c.retired}</Badge>}</td>
                  <td className={`${td} whitespace-nowrap text-right`}>
                    <div className="flex justify-end gap-2">
                      <Button variant="outlined" size="sm" onClick={() => open(s)}>
                        {c.edit}
                      </Button>
                      {s.isActive && !s.isDefault && s.isWorking ? (
                        <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", `/api/v1/configuration/statuses/${s.key}/default`))}>
                          {t.makeDefault}
                        </Button>
                      ) : null}
                      {s.isActive ? (
                        <Button
                          variant="destructive"
                          size="sm"
                          disabled={why !== null}
                          title={why === "default" ? t.defaultCannotRetire : why === "lastWorking" ? t.lastWorking : undefined}
                          onClick={() => save(() => send("PUT", `/api/v1/configuration/statuses/${s.key}/retired`), why === "default" ? t.defaultCannotRetire : t.lastWorking)}
                        >
                          {c.retire}
                        </Button>
                      ) : (
                        <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/statuses", formOf(s)))}>
                          {c.reactivate}
                        </Button>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      {target ? (
        <FormDialog
          key={target.opened}
          title={editing ? `${c.edit}: ${editing.name}` : c.add}
          intro={frozen ? t.flagsFrozen : undefined}
          onSave={submit}
          onClose={() => setTarget(null)}
          busy={state.kind === "saving"}
          saveLabel={c.save}
          cancelLabel={c.cancel}
        >
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {c.key}
              <input className={field} value={form.key} disabled={editing !== null} onChange={(e) => setForm({ ...form, key: e.target.value })} />
              {editing ? null : <span className="font-normal text-caption text-p4a-muted">{c.keyHint}</span>}
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
          <div className="flex flex-col gap-3">
            <FlagField name={t.working} hint={t.workingHint} checked={form.isWorking} disabled={frozen} onChange={(v) => setForm({ ...form, isWorking: v })} />
            <FlagField name={t.productive} hint={t.productiveHint} checked={form.isProductive} disabled={frozen} onChange={(v) => setForm({ ...form, isProductive: v })} />
            <FlagField name={t.paid} hint={t.paidHint} checked={form.isPaid} disabled={frozen} onChange={(v) => setForm({ ...form, isPaid: v })} />
            <FlagField name={t.billable} hint={t.billableHint} checked={form.isBillable} disabled={frozen} onChange={(v) => setForm({ ...form, isBillable: v })} />
          </div>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </>
  );
}
