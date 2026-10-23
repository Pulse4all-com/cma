"use client";

/**
 * Reasons on a CRM connection's page (Configuration → Sources, addition 0008zb): which property a deal's lost reason and a
 * ticket's reason come from, its state as the adapter read it (not mapped, not checked yet, a dropdown, refused), and the
 * property's options with the data-quality flag. A value is stored only from an enumeration (a dropdown): a text property
 * is refused, since free text can hold personal data, and this card says so. The options' values and labels come from
 * the customer records and are refreshed by the adapter (an option gone is archived, never deleted); the data-quality flag
 * is a person's and survives every refresh. It splits the reasons that say the lead was never a lead (a duplicate, a
 * wrong number) from the real lost reasons on Reports → Funnel. Nothing here names a property or an option.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { ReasonState, SourceDetail } from "@/lib/data";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { SaveNote, field, label, send, td, th, tr, useSave } from "./shared";

const RECORD_TYPES = ["deal", "ticket"] as const;
const PROPERTY_RE = /^[A-Za-z0-9_.:@/+=-]{1,100}$/;

export function SourceReasons({ detail, copy }: { detail: SourceDetail; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configSources;
  const base = `/api/v1/configuration/sources/${detail.connection.id}`;
  const { state, save } = useSave(c);
  const fieldOf = (type: (typeof RECORD_TYPES)[number]) => detail.fields.find((f) => f.entity === type && f.field === "reason") ?? null;
  const [drafts, setDrafts] = useState<Record<string, string>>(() =>
    Object.fromEntries(RECORD_TYPES.map((type) => [type, fieldOf(type)?.property ?? ""])));
  const [problem, setProblem] = useState<string | null>(null);
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const typeLabel = { deal: t.reasonDeal, ticket: t.reasonTicket };
  const stateBadge = (s: ReasonState) =>
    s === "enumeration" ? <Badge tone="success">{t.reasonStateEnumeration}</Badge>
      : s === "refused" ? <Badge tone="warning">{t.reasonStateRefused}</Badge>
      : s === "unchecked" ? <Badge tone="info">{t.reasonStateUnchecked}</Badge>
      : <Badge tone="neutral">{t.reasonStateNone}</Badge>;
  const stateText = { enumeration: t.reasonEnumeration, refused: t.reasonRefused, unchecked: t.reasonUnchecked, none: t.reasonNotMapped };

  async function map(type: (typeof RECORD_TYPES)[number]) {
    const property = (drafts[type] ?? "").trim();
    if (property !== "" && !PROPERTY_RE.test(property)) return setProblem(t.reasonPropertyProblem);
    setProblem(null);
    await save(() => send("PUT", `${base}/reason-field`, { recordType: type, property: property === "" ? null : property }));
  }

  return (
    <Card title={t.sectionReasons}>
      <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.reasonsIntro}</p>
      <div className="flex flex-col gap-8">
        {RECORD_TYPES.map((type) => {
          const f = fieldOf(type);
          const s: ReasonState = f?.state ?? "none";
          const options = detail.reasons.filter((r) => r.recordType === type);
          return (
            <div key={type} className="flex flex-col gap-4" data-testid={`source-reason-${type}`} data-state={s}>
              <h3 className="text-body font-semibold text-p4a-heading">{typeLabel[type]}</h3>
              <div className="flex flex-wrap items-end gap-4">
                <label className={label}>
                  <span className="flex items-center" data-hint-anchor="">{t.reasonProperty}{hint(t.reasonProperty, t.hintReasonProperty)}</span>
                  <input className={`${field} w-72`} value={drafts[type] ?? ""} maxLength={100} data-testid={`reason-property-${type}`}
                    onChange={(e) => setDrafts({ ...drafts, [type]: e.target.value })}
                    onKeyDown={(e) => { if (e.key === "Enter") void map(type); }} />
                </label>
                <Button variant="outlined" onClick={() => void map(type)} disabled={state.kind === "saving"}>{t.reasonMap}</Button>
                <span className="flex items-center gap-2 pb-2">{stateBadge(s)}</span>
              </div>
              <p className={`max-w-3xl text-small ${s === "refused" ? "text-p4a-warning" : "text-p4a-muted"}`} data-testid={`reason-state-${type}`}>
                {stateText[s].replace("{type}", f?.sourceType ?? "")}
              </p>
              {options.length === 0 ? (s === "enumeration" ? <p className="text-body text-p4a-muted">{t.reasonOptionsEmpty}</p> : null) : (
                <div className="overflow-x-auto">
                  <table className="w-full border-collapse text-body leading-table" data-testid={`source-reasons-${type}`}>
                    <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                      <tr>
                        <th className={th}><HintLabel label={t.reasonOption}>{hint(t.reasonOption, t.hintReasonOption)}</HintLabel></th>
                        <th className={`${th} text-right`}>{t.reasonOrder}</th>
                        <th className={th}>{t.status}</th>
                        {type === "deal" ? <th className={th}><HintLabel label={t.reasonDataQuality}>{hint(t.reasonDataQuality, t.hintReasonDataQuality)}</HintLabel></th> : null}
                      </tr>
                    </thead>
                    <tbody>
                      {options.map((o) => (
                        <tr key={o.value} className={`${tr} ${o.isActive ? "" : "text-p4a-muted"}`} data-reason={o.value}>
                          <td className={td}><span className="font-semibold">{o.label}</span> <span className="text-caption text-p4a-muted">({o.value})</span></td>
                          <td className={`${td} text-right tabular-nums text-small`}>{o.order}</td>
                          <td className={td}>{o.isActive ? <Badge tone="success">{t.on}</Badge> : <Badge tone="neutral">{t.reasonArchived}</Badge>}</td>
                          {type === "deal" ? (
                            <td className={td}>
                              <input type="checkbox" className="h-4 w-4 accent-p4a-deepblue" aria-label={`${t.reasonDataQuality}: ${o.label}`} checked={o.isDataQuality}
                                data-testid={`reason-dq-${o.value}`}
                                onChange={(e) => save(() => send("PUT", `${base}/reasons`, { recordType: type, value: o.value, isDataQuality: e.target.checked }))} />
                            </td>
                          ) : null}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          );
        })}
      </div>
      {problem ? <p className="mt-4 text-small text-p4a-error">{problem}</p> : null}
      <div className="mt-4"><SaveNote state={state} c={c} /></div>
    </Card>
  );
}
