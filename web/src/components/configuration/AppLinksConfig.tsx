"use client";

/**
 * App links: the buttons on Welcome, per tenant (label, https address, who sees it, order; add,
 * edit, retire, reactivate). Deep links only, never customer data; the database refuses anything
 * but https (400) and an unknown permission (404). Keyboard: A adds, R shows or hides retired links.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { ConfigAppLink, PermissionInfo } from "@/lib/data";
import { Badge, Button } from "../primitives";
import { FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

type Form = { key: string; label: string; address: string; permissionKey: string; sortOrder: number };

function formOf(l: ConfigAppLink | null): Form {
  return l ? { key: l.key, label: l.label, address: l.address, permissionKey: l.permissionKey ?? "", sortOrder: l.sortOrder } : { key: "", label: "", address: "https://", permissionKey: "", sortOrder: 100 };
}

export function AppLinksConfig({ links, permissions, copy }: { links: ConfigAppLink[]; permissions: PermissionInfo[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configAppLinks;
  const { state, save } = useSave(c);
  const [showRetired, setShowRetired] = useState(false);
  const [target, setTarget] = useState<{ link: ConfigAppLink | null; opened: number } | null>(null);
  const [form, setForm] = useState<Form>(formOf(null));
  const [problem, setProblem] = useState<string | null>(null);
  const rows = links.filter((l) => showRetired || l.isActive).sort((a, b) => Number(!a.isActive) - Number(!b.isActive) || a.sortOrder - b.sortOrder);

  function open(l: ConfigAppLink | null) {
    setForm(formOf(l));
    setProblem(null);
    setTarget({ link: l, opened: Date.now() });
  }

  async function submit() {
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(form.key) || form.label.trim() === "") {
      setProblem(c.keyHint);
      return;
    }
    if (!/^https:\/\/[^\s]+$/.test(form.address)) {
      setProblem(t.addressHint);
      return;
    }
    const body = { key: form.key, label: form.label.trim(), address: form.address, permissionKey: form.permissionKey || null, sortOrder: form.sortOrder };
    if (await save(() => send("PUT", "/api/v1/configuration/app-links", body))) setTarget(null);
  }

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
              <th className={th}>{t.label}</th>
              <th className={th}>{t.address}</th>
              <th className={th}>{t.permission}</th>
              <th className={`${th} text-right`}>{c.order}</th>
              <th className={th}>{c.active}</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((l) => (
              <tr key={l.key} className={l.isActive ? "" : "text-p4a-muted"}>
                <td className={td}>
                  <span className="font-semibold">{l.label}</span> <span className="text-small text-p4a-muted">({l.key})</span>
                </td>
                <td className={`${td} max-w-xs truncate text-small`} title={l.address}>{l.address}</td>
                <td className={`${td} text-small`}>{l.permissionKey ?? t.everyone}</td>
                <td className={`${td} text-right tabular-nums`}>{l.sortOrder}</td>
                <td className={td}>{l.isActive ? <Badge tone="success">{c.active}</Badge> : <Badge tone="neutral">{c.retired}</Badge>}</td>
                <td className={`${td} text-right`}>
                  <div className="flex justify-end gap-2">
                    <Button variant="outlined" size="sm" onClick={() => open(l)}>{c.edit}</Button>
                    {l.isActive ? (
                      <Button variant="destructive" size="sm" onClick={() => save(() => send("PUT", `/api/v1/configuration/app-links/${l.key}/retired`))}>{c.retire}</Button>
                    ) : (
                      <Button variant="outlined" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/app-links", { key: l.key, label: l.label, address: l.address, permissionKey: l.permissionKey, sortOrder: l.sortOrder }))}>{c.reactivate}</Button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {target ? (
        <FormDialog key={target.opened} title={target.link ? `${c.edit}: ${target.link.label}` : c.add} onSave={submit} onClose={() => setTarget(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {c.key}
              <input className={field} value={form.key} disabled={target.link !== null} onChange={(e) => setForm({ ...form, key: e.target.value })} />
            </label>
            <label className={label}>
              {t.label}
              <input className={field} value={form.label} maxLength={60} onChange={(e) => setForm({ ...form, label: e.target.value })} />
            </label>
            <label className={`${label} col-span-2`}>
              {t.address}
              <input className={field} value={form.address} maxLength={2000} onChange={(e) => setForm({ ...form, address: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.addressHint}</span>
            </label>
            <label className={label}>
              {t.permission}
              <select className={field} value={form.permissionKey} onChange={(e) => setForm({ ...form, permissionKey: e.target.value })}>
                <option value="">{t.everyone}</option>
                {permissions.map((p) => <option key={p.key} value={p.key}>{p.key}</option>)}
              </select>
            </label>
            <label className={label}>
              {c.order}
              <input className={field} type="number" min={0} max={9999} value={form.sortOrder} onChange={(e) => setForm({ ...form, sortOrder: Number(e.target.value) })} />
            </label>
          </div>
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </>
  );
}
