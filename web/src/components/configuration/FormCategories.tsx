"use client";

/**
 * Form categories (Configuration → Sources, addition 0008p): what the tenant's forms are for, to total them
 * on Reports → Forms. Add one, rename it or change its order, and switch it off (set_form_category,
 * set_form_category_status); a category switched off stays on the forms that have it and can no longer be
 * chosen for another. The code is the key and stays as it is once added. Nothing is assumed: the catalog is
 * the tenant's, filled by the runbook or here.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { FormCategory } from "@/lib/data";
import { formCategoryProblem } from "@/lib/sources";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

export function FormCategories({ categories, copy }: { categories: FormCategory[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configSources;
  const { state, save } = useSave(c);
  const seq = useRef(0);
  const [edit, setEdit] = useState<{ isNew: boolean; opened: number } | null>(null);
  const [draft, setDraft] = useState({ code: "", name: "", sortOrder: "100", isActive: true });
  const [problem, setProblem] = useState<string | null>(null);
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;

  function open(k: FormCategory | null) {
    setDraft(k ? { code: k.code, name: k.name, sortOrder: String(k.sortOrder), isActive: k.isActive }
      : { code: "", name: "", sortOrder: String(Math.max(0, ...categories.map((x) => x.sortOrder)) + 10), isActive: true });
    setProblem(null);
    setEdit({ isNew: k === null, opened: ++seq.current });
  }

  async function submit() {
    if (formCategoryProblem(draft)) return setProblem(t.categoryProblem);
    const body = { code: draft.code, name: draft.name.trim(), sortOrder: Number(draft.sortOrder), isActive: draft.isActive };
    if (await save(() => send("PUT", "/api/v1/configuration/form-categories", body))) setEdit(null);
  }

  return (
    <Card title={t.categoriesTitle}>
      <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
        <p className="max-w-3xl text-small text-p4a-muted">{t.categoriesIntro}</p>
        <Button variant="outlined" shortcut="A" data-shortcut="a" onClick={() => open(null)}>{t.addCategory}</Button>
      </div>
      {categories.length === 0 ? <p className="text-body text-p4a-muted">{t.categoriesEmpty}</p> : (
        <table className="w-full border-collapse text-body leading-table" data-testid="form-categories">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}><HintLabel label={t.categoryName}>{hint(t.categoryName, t.hintCategoryName)}</HintLabel></th>
              <th className={th}><HintLabel label={t.categoryCode}>{hint(t.categoryCode, t.hintCategoryCode)}</HintLabel></th>
              <th className={`${th} text-right`}><HintLabel label={t.categoryOrder}>{hint(t.categoryOrder, t.hintCategoryOrder)}</HintLabel></th>
              <th className={`${th} text-right`}><HintLabel label={t.categoryForms}>{hint(t.categoryForms, t.hintCategoryForms)}</HintLabel></th>
              <th className={th}><HintLabel label={t.categoryActive}>{hint(t.categoryActive, t.hintCategoryActive)}</HintLabel></th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {categories.map((k) => (
              <tr key={k.code} className={`${tr} ${k.isActive ? "" : "text-p4a-muted"}`} data-category={k.code}>
                <td className={`${td} font-semibold`}>{k.name}</td>
                <td className={`${td} text-small`}>{k.code}</td>
                <td className={`${td} tabular text-right`}>{k.sortOrder}</td>
                <td className={`${td} tabular text-right`}>{k.forms}</td>
                <td className={td}>{k.isActive ? <Badge tone="success">{t.on}</Badge> : <Badge tone="neutral">{t.off}</Badge>}</td>
                <td className={`${td} text-right`}><Button variant="outlined" size="sm" onClick={() => open(k)}>{c.edit}</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {edit === null ? <SaveNote state={state} c={c} /> : (
        <FormDialog key={edit.opened} title={edit.isNew ? t.addCategory : `${t.editCategory}: ${draft.code}`} onSave={submit} onClose={() => setEdit(null)}
          busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.categoryCode}
              <input className={field} value={draft.code} maxLength={40} readOnly={!edit.isNew} onChange={(e) => setDraft({ ...draft, code: e.target.value.trim() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.hintCategoryCode}</span>
            </label>
            <label className={label}>
              {t.categoryName}
              <input className={field} value={draft.name} maxLength={60} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
            </label>
            <label className={label}>
              {t.categoryOrder}
              <input className={field} inputMode="numeric" value={draft.sortOrder} maxLength={4} onChange={(e) => setDraft({ ...draft, sortOrder: e.target.value.trim() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.hintCategoryOrder}</span>
            </label>
          </div>
          <FlagField name={t.categoryActive} hint={t.hintCategoryActive} checked={draft.isActive} onChange={(v) => setDraft({ ...draft, isActive: v })} />
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      )}
    </Card>
  );
}
