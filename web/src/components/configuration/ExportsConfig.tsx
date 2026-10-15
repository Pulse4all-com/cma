"use client";

/**
 * Exports: the five CSV settings of 0003b as choices, each saved at once, with a preview line in
 * the chosen format, and the two minute settings (adherence tolerance, the forgotten clock-out
 * grace); since addition 0008j also the seconds of talk time from which an outbound call is connected,
 * which the telephony connection's Sources page links to; since addition 0008l the two invitation settings
 * (how many days a link works, the email domains invitations may go to). Use default resets a value to the catalog's.
 * Every value goes through /api/v1/configuration/settings and is validated by the database against
 * its catalog.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import type { TenantSetting } from "@/lib/data";
import {
  EXPORT_SETTING_KEYS, EXPORT_SETTING_VALUES, MINUTE_SETTING_KEYS, SECOND_SETTING_KEYS, exportPreview, parseMinutes, settingAnchor,
  type ExportSettingKey, type MinuteSettingKey, type SecondSettingKey,
} from "@/lib/configuration";
import { FOLLOW_UP_SETTING_KEYS, parseFollowUpSetting, type FollowUpSettingKey } from "@/lib/follow-up";
import { normaliseDomains, parseValidDays } from "@/lib/invitations";
import { Button } from "../primitives";
import { SaveNote, field, label, send, useSave } from "./shared";

/** The Follow-up settings (addition 0008o): their labels and hints in copy.configExports */
const FOLLOW_UP_KEYS: Record<FollowUpSettingKey, keyof Copy["configExports"]> = {
  "tickets.sla_minutes": "tickets_sla_minutes", "tickets.sla_warning_pct": "tickets_sla_warning_pct",
  "leads.age_buckets_business_days": "leads_age_buckets_business_days", "tasks.callback_window_minutes": "tasks_callback_window_minutes",
};
const FOLLOW_UP_HINTS: Record<FollowUpSettingKey, keyof Copy["configExports"]> = {
  "tickets.sla_minutes": "slaHint", "tickets.sla_warning_pct": "pctHint", "leads.age_buckets_business_days": "bucketsHint", "tasks.callback_window_minutes": "windowHint",
};

export function ExportsConfig({ settings, copy }: { settings: TenantSetting[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configExports;
  const { state, save } = useSave(c);
  const [minutes, setMinutes] = useState<Partial<Record<MinuteSettingKey | SecondSettingKey, string>>>({});
  const [days, setDays] = useState<string | undefined>(undefined);
  const [domains, setDomains] = useState<string | undefined>(undefined);
  // the Follow-up settings (0008o), each saved on blur once it parses, as the minute settings
  const [followUp, setFollowUp] = useState<Partial<Record<FollowUpSettingKey, string>>>({});

  async function saveFollowUp(key: FollowUpSettingKey) {
    const text = followUp[key];
    if (text === undefined) return;
    const v = parseFollowUpSetting(key, text);
    if (v === null) return;
    if (v !== valueOf(key)?.value) await save(() => send("PUT", "/api/v1/configuration/settings", { key, value: v }));
    setFollowUp((prev) => { const next = { ...prev }; delete next[key]; return next; });
  }
  const valueOf = (key: string) => settings.find((s) => s.key === key);
  const preview = exportPreview(settings, {
    date: copy.exports.date, person: copy.exports.person, worked: copy.exports.worked, bom: t.values_true, noBom: t.values_false,
  });

  const VALUE_KEYS: Record<string, keyof Copy["configExports"]> = {
    comma: "values_comma", semicolon: "values_semicolon", tab: "values_tab", point: "values_point",
    "yyyy-mm-dd": "values_yyyy_mm_dd", "dd-mm-yyyy": "values_dd_mm_yyyy", "dd/mm/yyyy": "values_dd_mm_yyyy_slash", "mm/dd/yyyy": "values_mm_dd_yyyy_slash",
    decimal_hours: "values_decimal_hours", "hh:mm": "values_hh_mm", minutes: "values_minutes", true: "values_true", false: "values_false",
  };
  const LABEL_KEYS: Record<ExportSettingKey, keyof Copy["configExports"]> = {
    "export.csv.separator": "labels_export_csv_separator", "export.csv.decimal_mark": "labels_export_csv_decimal_mark",
    "export.csv.date_format": "labels_export_csv_date_format", "export.csv.duration_format": "labels_export_csv_duration_format", "export.csv.utf8_bom": "labels_export_csv_utf8_bom",
  };
  const MINUTE_KEYS: Record<MinuteSettingKey | SecondSettingKey, keyof Copy["configExports"]> = {
    "roster.adherence_tolerance_minutes": "roster_adherence_tolerance_minutes", "workday.auto_close_grace_minutes": "workday_auto_close_grace_minutes",
    "telephony.connected_min_seconds": "telephony_connected_min_seconds",
  };
  const valueLabel = (v: string) => (VALUE_KEYS[v] ? t[VALUE_KEYS[v]] : v);

  async function saveMinutes(key: MinuteSettingKey | SecondSettingKey) {
    const text = minutes[key];
    if (text === undefined) return;
    const n = parseMinutes(text);
    if (n === null) return;
    if (String(n) === valueOf(key)?.value) return;
    await save(() => send("PUT", "/api/v1/configuration/settings", { key, value: String(n) }));
    setMinutes((prev) => { const next = { ...prev }; delete next[key]; return next; });
  }

  async function saveDays() {
    if (days === undefined) return;
    const n = parseValidDays(days);
    if (n === null || String(n) === valueOf("auth.invitation_valid_days")?.value) return;
    await save(() => send("PUT", "/api/v1/configuration/settings", { key: "auth.invitation_valid_days", value: String(n) }));
    setDays(undefined);
  }

  async function saveDomains() {
    if (domains === undefined) return;
    const v = normaliseDomains(domains);
    if (v === null || v === (valueOf("auth.invitation_email_domains")?.value ?? "")) return;
    // an empty list is the catalog's default (no domain check): reset rather than store an empty value
    await save(() => send("PUT", "/api/v1/configuration/settings", { key: "auth.invitation_email_domains", value: v === "" ? null : v }));
    setDomains(undefined);
  }

  const daysSetting = valueOf("auth.invitation_valid_days");
  const domainsSetting = valueOf("auth.invitation_email_domains");
  const badDays = days !== undefined && parseValidDays(days) === null;
  const badDomains = domains !== undefined && normaliseDomains(domains) === null;

  return (
    <div className="flex flex-col gap-8">
      <SaveNote state={state} c={c} />
      <section className="grid grid-cols-2 gap-6">
        {EXPORT_SETTING_KEYS.map((key: ExportSettingKey) => {
          const s = valueOf(key);
          return (
            <label key={key} className={label}>
              <span>
                {t[LABEL_KEYS[key]]}
                {s?.isDefault ? <span className="ml-2 font-normal text-caption text-p4a-muted">({t.isDefault})</span> : null}
              </span>
              <span className="flex gap-2">
                <select className={`${field} flex-1`} value={s?.value ?? ""} onChange={(e) => save(() => send("PUT", "/api/v1/configuration/settings", { key, value: e.target.value }))}>
                  {EXPORT_SETTING_VALUES[key].map((v) => <option key={v} value={v}>{valueLabel(v)}</option>)}
                </select>
                {s && !s.isDefault ? (
                  <Button variant="text" size="md" onClick={() => save(() => send("PUT", "/api/v1/configuration/settings", { key, value: null }))}>
                    {t.resetToDefault}
                  </Button>
                ) : null}
              </span>
            </label>
          );
        })}
      </section>

      <section>
        <h2 className="text-panel font-semibold text-p4a-heading">{t.preview}</h2>
        <pre className="mt-2 overflow-x-auto whitespace-pre rounded-card border border-p4a-border bg-p4a-neutral-surface p-4 font-sans text-small">{preview.join("\n")}</pre>
      </section>

      <section>
        <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.otherSettings}</h2>
        <div className="grid grid-cols-2 gap-6">
          {[...MINUTE_SETTING_KEYS, ...SECOND_SETTING_KEYS].map((key) => {
            const s = valueOf(key);
            const text = minutes[key] ?? s?.value ?? "";
            const bad = minutes[key] !== undefined && parseMinutes(minutes[key] ?? "") === null;
            const seconds = (SECOND_SETTING_KEYS as readonly string[]).includes(key);
            return (
              <label key={key} id={settingAnchor(key)} className={`${label} scroll-mt-24`}>
                <span>
                  {t[MINUTE_KEYS[key]]}
                  {s?.isDefault ? <span className="ml-2 font-normal text-caption text-p4a-muted">({t.isDefault})</span> : null}
                </span>
                <span className="flex gap-2">
                  <input
                    className={`${field} w-32 tabular-nums ${bad ? "border-p4a-error" : ""}`}
                    inputMode="numeric"
                    value={text}
                    onChange={(e) => setMinutes({ ...minutes, [key]: e.target.value })}
                    onBlur={() => saveMinutes(key)}
                    onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
                  />
                  {s && !s.isDefault ? (
                    <Button variant="text" size="md" onClick={() => save(() => send("PUT", "/api/v1/configuration/settings", { key, value: null }))}>
                      {t.resetToDefault}
                    </Button>
                  ) : null}
                </span>
                <span className="font-normal text-caption text-p4a-muted">{seconds ? t.secondsHint : t.minutesHint}</span>
              </label>
            );
          })}
        </div>
      </section>

      <section data-testid="invitation-settings">
        <h2 className="mb-4 text-panel font-semibold text-p4a-heading">{t.invitations}</h2>
        <div className="grid grid-cols-2 gap-6">
          <label id={settingAnchor("auth.invitation_valid_days")} className={`${label} scroll-mt-24`}>
            <span>
              {t.auth_invitation_valid_days}
              {daysSetting?.isDefault ? <span className="ml-2 font-normal text-caption text-p4a-muted">({t.isDefault})</span> : null}
            </span>
            <span className="flex gap-2">
              <input className={`${field} w-32 tabular-nums ${badDays ? "border-p4a-error" : ""}`} inputMode="numeric"
                value={days ?? daysSetting?.value ?? ""} onChange={(e) => setDays(e.target.value)} onBlur={saveDays}
                onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
              {daysSetting && !daysSetting.isDefault ? (
                <Button variant="text" size="md" onClick={() => save(() => send("PUT", "/api/v1/configuration/settings", { key: "auth.invitation_valid_days", value: null }))}>
                  {t.resetToDefault}
                </Button>
              ) : null}
            </span>
            <span className="font-normal text-caption text-p4a-muted">{t.daysHint}</span>
          </label>
          <label id={settingAnchor("auth.invitation_email_domains")} className={`${label} scroll-mt-24`}>
            <span>
              {t.auth_invitation_email_domains}
              {domainsSetting?.isDefault ? <span className="ml-2 font-normal text-caption text-p4a-muted">({t.isDefault})</span> : null}
            </span>
            <input className={`${field} ${badDomains ? "border-p4a-error" : ""}`} maxLength={100} placeholder="example.com"
              value={domains ?? domainsSetting?.value ?? ""} onChange={(e) => setDomains(e.target.value)} onBlur={saveDomains}
              onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }} />
            <span className={`font-normal text-caption ${badDomains ? "text-p4a-error" : "text-p4a-muted"}`}>{badDomains ? t.domainsProblem : t.domainsHint}</span>
          </label>
        </div>
      </section>

      <section data-testid="follow-up-settings">
        <h2 className="mb-1 text-panel font-semibold text-p4a-heading">{t.followUp}</h2>
        <p className="mb-4 max-w-3xl text-small text-p4a-muted">{t.followUpIntro}</p>
        <div className="grid grid-cols-2 gap-6">
          {FOLLOW_UP_SETTING_KEYS.map((key) => {
            const s = valueOf(key);
            const text = followUp[key] ?? s?.value ?? "";
            const bad = followUp[key] !== undefined && parseFollowUpSetting(key, followUp[key] ?? "") === null;
            const buckets = key === "leads.age_buckets_business_days";
            return (
              <label key={key} id={settingAnchor(key)} className={`${label} scroll-mt-24`}>
                <span>
                  {t[FOLLOW_UP_KEYS[key]]}
                  {s?.isDefault ? <span className="ml-2 font-normal text-caption text-p4a-muted">({t.isDefault})</span> : null}
                </span>
                <span className="flex gap-2">
                  <input
                    className={`${field} ${buckets ? "w-48" : "w-32"} tabular-nums ${bad ? "border-p4a-error" : ""}`}
                    inputMode={buckets ? "text" : "numeric"}
                    maxLength={buckets ? 24 : 6}
                    value={text}
                    onChange={(e) => setFollowUp({ ...followUp, [key]: e.target.value })}
                    onBlur={() => saveFollowUp(key)}
                    onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
                  />
                  {s && !s.isDefault ? (
                    <Button variant="text" size="md" onClick={() => save(() => send("PUT", "/api/v1/configuration/settings", { key, value: null }))}>
                      {t.resetToDefault}
                    </Button>
                  ) : null}
                </span>
                <span className={`font-normal text-caption ${bad ? "text-p4a-error" : "text-p4a-muted"}`}>{bad ? t.followUpProblem : t[FOLLOW_UP_HINTS[key]]}</span>
              </label>
            );
          })}
        </div>
      </section>
    </div>
  );
}
