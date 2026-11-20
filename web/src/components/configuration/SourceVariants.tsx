"use client";

/**
 * The variant mapping on a subscriptions connection's page (Configuration → Sources, addition 0009ze, brief B39c C.1):
 * what each product variant of the store's subscription app is (a device with its model and devices per unit, an
 * accessory, a service or other) and its proposition. Device units and the propositions are counted from it. Variants on
 * an active line without a mapping come first. The catalog's texts are the store's merchant texts, never a customer's.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { SubscriptionVariant, SubscriptionVariants, VariantLineKind } from "@/lib/data";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { FormDialog, SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

const KINDS: readonly VariantLineKind[] = ["device", "accessory", "service", "other"];

export function SourceVariants({ connectionId, variants, copy }: { connectionId: string; variants: SubscriptionVariants;
  copy: Pick<Copy, "configSources" | "configuration"> & { hints: Pick<Copy["hints"], "about"> } }) {
  const c = copy.configuration;
  const t = copy.configSources;
  const { state, save } = useSave(c);
  const seq = useRef(0);
  const [open, setOpen] = useState<{ n: number; v: SubscriptionVariant } | null>(null);
  const [draft, setDraft] = useState({ lineKind: "" as VariantLineKind | "", modelKey: "", devicesPerUnit: "1", proposition: "" });
  const [problem, setProblem] = useState<string | null>(null);
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const kindLabel = (k: VariantLineKind) => t[`lineKind_${k}`];
  const modelName = (key: string | null) => variants.models.find((m) => m.key === key)?.name ?? key ?? "";

  function edit(v: SubscriptionVariant) {
    setDraft({ lineKind: v.lineKind ?? "", modelKey: v.modelKey ?? variants.models[0]?.key ?? "", devicesPerUnit: String(v.devicesPerUnit ?? 1),
      proposition: v.proposition ?? "" });
    setProblem(null);
    setOpen({ n: ++seq.current, v });
  }

  async function submit() {
    if (!open) return;
    const kind = draft.lineKind === "" ? null : draft.lineKind;
    const units = Number(draft.devicesPerUnit);
    if (kind === "device" && (!draft.modelKey || !Number.isInteger(units) || units < 0 || units > 20)) return setProblem(t.variantProblem);
    const body = { connectionId, variantSourceId: open.v.variantSourceId, lineKind: kind, modelKey: kind === "device" ? draft.modelKey : null,
      devicesPerUnit: kind === "device" ? units : kind === null ? null : 0, proposition: kind === null ? null : draft.proposition || null };
    if (await save(() => send("PUT", "/api/v1/configuration/subscription-variants", body))) setOpen(null);
  }

  return (
    <Card title={t.sectionVariants}>
      <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.variantsIntro}</p>
      {variants.variants.length === 0 ? <p className="text-body text-p4a-muted">{t.variantsEmpty}</p> : (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-body leading-table" data-testid="source-variants">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.colVariant}</th>
                <th className={th}>{t.colSku}</th>
                <th className={`${th} text-right`}><HintLabel label={t.colActiveLines}>{hint(t.colActiveLines, t.hintActiveLines)}</HintLabel></th>
                <th className={th}>{t.colLineKind}</th>
                <th className={th}>{t.colModel}</th>
                <th className={`${th} text-right`}><HintLabel label={t.colDevicesPerUnit}>{hint(t.colDevicesPerUnit, t.hintDevicesPerUnit)}</HintLabel></th>
                <th className={th}><HintLabel label={t.colProposition}>{hint(t.colProposition, t.hintProposition)}</HintLabel></th>
                <th className={th}></th>
              </tr>
            </thead>
            <tbody>
              {variants.variants.map((v) => (
                <tr key={v.variantSourceId} className={tr} data-variant={v.variantSourceId}>
                  <td className={td}>
                    <span className="font-semibold">{v.productTitle ?? v.variantSourceId}</span>
                    {v.variantTitle ? <span className="text-small text-p4a-muted"> · {v.variantTitle}</span> : null}
                    {v.inCatalog ? null : <span className="text-caption text-p4a-muted"> ({t.notInCatalog})</span>}
                  </td>
                  <td className={`${td} text-small`}>{v.sku ?? "–"}</td>
                  <td className={`${td} text-right tabular-nums`}>{v.activeLines}</td>
                  <td className={td}>{v.lineKind ? kindLabel(v.lineKind) : <Badge tone={v.activeLines > 0 ? "warning" : "neutral"}>{t.notMapped}</Badge>}</td>
                  <td className={`${td} text-small`}>{v.lineKind === "device" ? modelName(v.modelKey) : "–"}</td>
                  <td className={`${td} text-right tabular-nums`}>{v.lineKind ? v.devicesPerUnit : "–"}</td>
                  <td className={`${td} text-small`}>{v.proposition ?? "–"}</td>
                  <td className={`${td} text-right`}>
                    <Button variant="outlined" size="sm" onClick={() => edit(v)}>{v.lineKind ? t.editVariant : t.mapVariant}</Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {open === null ? <div className="mt-4"><SaveNote state={state} c={c} /></div> : (
        <FormDialog key={open.n} title={`${t.mapVariant}: ${open.v.productTitle ?? open.v.variantSourceId}${open.v.variantTitle ? ` · ${open.v.variantTitle}` : ""}`}
          intro={t.variantDialogIntro} onSave={submit} onClose={() => setOpen(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <label className={label}>
            {t.colLineKind}
            <select className={field} value={draft.lineKind} onChange={(e) => setDraft({ ...draft, lineKind: e.target.value as VariantLineKind | "" })}>
              <option value="">{t.removeMapping}</option>
              {KINDS.map((k) => <option key={k} value={k}>{kindLabel(k)}</option>)}
            </select>
          </label>
          {draft.lineKind === "device" ? (
            <>
              <label className={label}>
                {t.colModel}
                <select className={field} value={draft.modelKey} onChange={(e) => setDraft({ ...draft, modelKey: e.target.value })}>
                  {variants.models.map((m) => <option key={m.key} value={m.key}>{m.name} ({m.key})</option>)}
                </select>
              </label>
              <label className={label}>
                {t.colDevicesPerUnit}
                <input className={field} type="number" min={0} max={20} step={1} value={draft.devicesPerUnit}
                  onChange={(e) => setDraft({ ...draft, devicesPerUnit: e.target.value })} />
                <span className="font-normal text-caption text-p4a-muted">{t.hintDevicesPerUnit}</span>
              </label>
            </>
          ) : null}
          {draft.lineKind !== "" ? (
            <label className={label}>
              {t.colProposition}
              <select className={field} value={draft.proposition} onChange={(e) => setDraft({ ...draft, proposition: e.target.value })}>
                <option value="">{t.noProposition}</option>
                {variants.propositions.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </label>
          ) : null}
          {problem ? <p className="text-small text-p4a-error">{problem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      )}
    </Card>
  );
}
