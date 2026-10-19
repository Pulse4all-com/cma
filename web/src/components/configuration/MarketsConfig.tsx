"use client";

/**
 * Markets (addition 0008e): the tenant's markets with their aliases, office hours and holidays, three
 * cards on one page. Every write goes through the function owning the value (upsert_market,
 * set_market_status, set_market_alias, remove_market_alias, set_business_hours, set_business_holiday,
 * remove_business_holiday); the rules the database applies are explained before sending, from
 * lib/sources. A market with hours of its own uses only those, so giving a market its own hours starts
 * from the default row, and "Use the default" clears them; each a whole week in one transaction.
 *
 * Keyboard: A adds a market, I adds an alias, H adds a holiday; a market's week opens in a dialog;
 * Ctrl+Enter saves a dialog, Esc closes it.
 */
import { useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { MarketConfig, MarketsConfig as MarketsData, SkillInfo } from "@/lib/data";
import { effectiveHours, marketFormProblem, normalizeAlias, parseDay, parseOfficeHours, type MarketForm } from "@/lib/sources";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge, Button, Card } from "../primitives";
import { FlagField, FormDialog, SaveNote, field, label, send, td, th, useSave } from "./shared";

const WEEKDAYS = [1, 2, 3, 4, 5, 6, 7];

type Form = MarketForm & { sortOrder: number; active: boolean };

function formOf(m: MarketConfig | null): Form {
  return m
    ? { code: m.code, name: m.name, timeZone: m.timeZone, languageCode: m.languageCode, currency: m.currency, languageSkillKey: m.languageSkillKey, minLanguageLevel: m.minLanguageLevel, sortOrder: m.sortOrder, active: m.isActive }
    : { code: "", name: "", timeZone: "", languageCode: "", currency: "", languageSkillKey: null, minLanguageLevel: null, sortOrder: 100, active: true };
}

export function MarketsConfig({ data, skills, copy }: { data: MarketsData; skills: SkillInfo[]; copy: Copy }) {
  const c = copy.configuration;
  const t = copy.configMarkets;
  const { state, save } = useSave(c);
  // a fresh key per opening, so every dialog starts from the values as they stand
  const seq = useRef(0);
  const tick = () => ++seq.current;
  const hint = (labelText: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", labelText)} text={text} />;
  const days = t.weekdays.split(" ");
  const languageSkills = skills.filter((s) => s.dimension === "language" && s.isActive);

  const [marketEdit, setMarketEdit] = useState<{ market: MarketConfig | null; opened: number } | null>(null);
  const [form, setForm] = useState<Form>(formOf(null));
  const [marketProblem, setMarketProblem] = useState<string | null>(null);
  const [aliasOpen, setAliasOpen] = useState<number | null>(null);
  const [alias, setAlias] = useState({ text: "", code: data.markets[0]?.code ?? "" });
  const [aliasProblem, setAliasProblem] = useState<string | null>(null);
  const [week, setWeek] = useState<{ market: string; opened: number; texts: string[] } | null>(null);
  const [weekProblem, setWeekProblem] = useState<string | null>(null);
  const [holidayOpen, setHolidayOpen] = useState<number | null>(null);
  const [holiday, setHoliday] = useState({ day: "", market: "*", name: "" });
  const [holidayProblem, setHolidayProblem] = useState<string | null>(null);

  const levelsOf = (key: string | null) => (key ? languageSkills.find((s) => s.key === key)?.levels ?? [] : []);

  function openMarket(m: MarketConfig | null) {
    setForm(formOf(m));
    setMarketProblem(null);
    setMarketEdit({ market: m, opened: tick() });
  }

  async function saveMarket() {
    const f = { ...form, code: form.code.trim().toUpperCase(), name: form.name.trim(), timeZone: form.timeZone.trim(), languageCode: form.languageCode.trim().toLowerCase(), currency: form.currency.trim().toUpperCase() };
    const p = marketFormProblem(f);
    if (p) {
      setMarketProblem({ uk: t.ukProblem, code: t.codeProblem, name: t.nameProblem, zone: t.zoneProblem, language: t.languageProblem, currency: t.currencyProblem, level: t.levelProblem }[p]);
      return;
    }
    if (!marketEdit?.market && data.markets.some((m) => m.code === f.code)) {
      setMarketProblem(t.codeProblem);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/markets", f))) setMarketEdit(null);
  }

  async function saveAlias() {
    const a = normalizeAlias(alias.text);
    if (a === null || !alias.code) {
      setAliasProblem(t.aliasProblem);
      return;
    }
    if (await save(() => send("PUT", "/api/v1/configuration/markets/aliases", { alias: a, code: alias.code }))) setAliasOpen(null);
  }

  async function saveHoliday() {
    const day = parseDay(holiday.day);
    if (day === null) return setHolidayProblem(t.dayProblem);
    if (holiday.name.trim().length === 0 || holiday.name.trim().length > 100) return setHolidayProblem(t.holidayNameProblem);
    if (await save(() => send("PUT", "/api/v1/configuration/markets/holidays", { market: holiday.market, day, name: holiday.name.trim() }))) setHolidayOpen(null);
  }

  const hasOwn = (code: string) => data.hours.some((h) => h.market === code);

  /** A market's week in one dialog; a market without hours of its own starts from the default row */
  function openWeek(code: string) {
    const from = code === "*" || hasOwn(code) ? code : "*";
    setWeekProblem(null);
    setWeek({ market: code, opened: tick(), texts: WEEKDAYS.map((d) => effectiveHours(data.hours, from, d).hours.split(",").join(", ")) });
  }

  async function saveWeek() {
    if (!week) return;
    const parsed = week.texts.map((x) => parseOfficeHours(x));
    const bad = parsed.findIndex((x) => x === null);
    if (bad >= 0) {
      setWeekProblem(`${days[bad]}: ${t.hoursProblem}`);
      return;
    }
    if (await putDays(week.market, WEEKDAYS.map((weekday, i) => ({ weekday, hours: parsed[i]! })))) setWeek(null);
  }
  const putDays = (market: string, list: { weekday: number; hours: string }[]) => save(() => send("PUT", "/api/v1/configuration/markets/hours", { market, days: list }), t.hoursProblem);
  const aliasHolder = (text: string) => {
    const a = normalizeAlias(text);
    return a ? data.markets.find((m) => m.aliases.includes(a)) ?? null : null;
  };

  return (
    <>
      <div className="flex justify-end"><SaveNote state={state} c={c} /></div>

      {/* ---- markets with their aliases ---- */}
      <Card title={t.sectionMarkets}>
        <div className="-mt-2 mb-4 flex justify-end gap-3">
          <Button variant="outlined" shortcut="I" data-shortcut="i" disabled={data.markets.length === 0}
            onClick={() => { setAlias({ text: "", code: data.markets[0]?.code ?? "" }); setAliasProblem(null); setAliasOpen(tick()); }}>{t.addAlias}</Button>
          <Button variant="primary" shortcut="A" data-shortcut="a" onClick={() => openMarket(null)}>{t.addMarket}</Button>
        </div>
        <table className="w-full border-collapse text-body" data-testid="markets">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={th}>{t.sectionMarkets}</th>
              <th className={th}>{t.zoneLanguageCurrency}</th>
              <th className={th}><HintLabel label={t.languageSkill}>{hint(t.languageSkill, t.hintLanguageSkill)}</HintLabel></th>
              <th className={th}><HintLabel label={t.aliases}>{hint(t.aliases, t.hintAliases)}</HintLabel></th>
              <th className={th}>{t.status}</th>
              <th className={th}></th>
            </tr>
          </thead>
          <tbody>
            {data.markets.map((m) => (
              <tr key={m.code} className={m.isActive ? "" : "text-p4a-muted"} data-market={m.code}>
                <td className={td}><span className="font-semibold">{m.code}</span><span className="block text-small">{m.name}</span></td>
                <td className={`${td} text-small`}>{m.timeZone}<span className="block text-p4a-muted">{m.languageCode} · {m.currency}</span></td>
                <td className={`${td} text-small`}>
                  {m.languageSkillKey ? `${languageSkills.find((s) => s.key === m.languageSkillKey)?.name ?? m.languageSkillKey}${m.minLanguageLevel ? ` · ${levelsOf(m.languageSkillKey).find((l) => l.level === m.minLanguageLevel)?.name ?? m.minLanguageLevel}` : ""}` : t.noSkill}
                </td>
                <td className={td}>
                  <div className="flex flex-wrap gap-1">
                    {m.aliases.length === 0 ? <span className="text-small text-p4a-muted">{t.noAliases}</span> : m.aliases.map((a) => (
                      <span key={a} className="inline-flex items-center gap-1 rounded-button bg-p4a-bgblue px-2 py-0.5 text-caption text-p4a-deepblue">
                        {a}
                        <button type="button" aria-label={t.removeAlias.replace("{alias}", a)} title={t.removeAlias.replace("{alias}", a)} className="px-1 font-semibold hover:text-p4a-error"
                          onClick={() => save(() => send("PUT", "/api/v1/configuration/markets/aliases", { alias: a, code: null }))}>×</button>
                      </span>
                    ))}
                  </div>
                </td>
                <td className={td}>{m.isActive ? <Badge tone="success">{t.active}</Badge> : <Badge tone="neutral">{t.inactive}</Badge>}</td>
                <td className={`${td} text-right`}><Button variant="outlined" size="sm" onClick={() => openMarket(m)}>{c.edit}</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      {/* ---- office hours ---- */}
      <Card title={t.sectionHours}>
        <p className="-mt-2 mb-4 max-w-3xl text-small text-p4a-muted">{t.hoursIntro}</p>
        <table className="w-full table-fixed border-collapse text-body" data-testid="office-hours">
          <thead className="bg-p4a-bgblue text-small text-p4a-heading">
            <tr>
              <th className={`${th} w-44`}>{t.sectionMarkets}</th>
              {WEEKDAYS.map((d) => <th key={d} className={th}>{days[d - 1]}{d === 1 ? hint(t.sectionHours, t.hintHours) : null}</th>)}
              <th className={`${th} w-40`}></th>
            </tr>
          </thead>
          <tbody>
            {["*", ...data.markets.map((m) => m.code)].map((code) => {
              const own = code === "*" || hasOwn(code);
              return (
                <tr key={code} data-hours={code} className={own ? "" : "text-p4a-muted"}>
                  <td className={td}>
                    <span className="font-semibold">{code === "*" ? t.defaultRow : code}</span>
                    <span className="block text-caption text-p4a-muted">{code === "*" ? t.defaultRowHint : own ? "" : t.followsDefault}</span>
                  </td>
                  {WEEKDAYS.map((d) => {
                    const eff = effectiveHours(data.hours, code, d);
                    return (
                      <td key={d} className={`${td} text-caption tabular-nums`}>
                        {eff.hours ? eff.hours.split(",").map((r) => <span key={r} className="block whitespace-nowrap">{r.replace("-", "–")}</span>) : <span className="text-p4a-muted">{t.closed}</span>}
                      </td>
                    );
                  })}
                  <td className={`${td} text-right`}>
                    <div className="flex flex-col items-end gap-1">
                      <Button variant="outlined" size="sm" title={own ? undefined : t.ownHoursHint} onClick={() => openWeek(code)}>{own ? t.editHours : t.ownHours}</Button>
                      {code !== "*" && own ? (
                        <Button variant="text" size="sm" onClick={() => putDays(code, WEEKDAYS.map((weekday) => ({ weekday, hours: "" })))}>{t.useDefault}</Button>
                      ) : null}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </Card>

      {/* ---- holidays ---- */}
      <Card title={t.sectionHolidays}>
        <div className="-mt-2 mb-4 flex items-start justify-between gap-4">
          <p className="max-w-3xl text-small text-p4a-muted">{t.holidaysIntro}</p>
          <Button variant="outlined" shortcut="H" data-shortcut="h"
            onClick={() => { setHoliday({ day: "", market: "*", name: "" }); setHolidayProblem(null); setHolidayOpen(tick()); }}>{t.addHoliday}</Button>
        </div>
        {data.holidays.length === 0 ? <p className="text-body text-p4a-muted">{t.holidaysEmpty}</p> : (
          <table className="w-full border-collapse text-body" data-testid="holidays">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr><th className={th}>{t.day}</th><th className={th}>{t.holidayMarket}</th><th className={th}>{t.holidayName}</th><th className={th}></th></tr>
            </thead>
            <tbody>
              {data.holidays.map((h) => (
                <tr key={`${h.market}:${h.day}`}>
                  <td className={`${td} tabular-nums`}>{h.day}</td>
                  <td className={td}>{h.market === "*" ? t.everyMarket : h.market}</td>
                  <td className={td}>{h.name}</td>
                  <td className={`${td} text-right`}>
                    <Button variant="text" size="sm" onClick={() => save(() => send("PUT", "/api/v1/configuration/markets/holidays", { market: h.market, day: h.day, name: null }))}>{t.removeHoliday}</Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>

      {marketEdit ? (
        <FormDialog key={marketEdit.opened} title={marketEdit.market ? `${t.editMarket}: ${marketEdit.market.code}` : t.addMarket} onSave={saveMarket} onClose={() => setMarketEdit(null)}
          busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel} wide>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.code}
              <input className={field} value={form.code} maxLength={2} disabled={marketEdit.market !== null} onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.codeHint}</span>
            </label>
            <label className={label}>
              {t.name}
              <input className={field} value={form.name} maxLength={80} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            </label>
            <label className={label}>
              {t.timeZone}
              <input className={field} value={form.timeZone} maxLength={64} onChange={(e) => setForm({ ...form, timeZone: e.target.value })} />
              <span className="font-normal text-caption text-p4a-muted">{t.timeZoneHint}</span>
            </label>
            <label className={label}>
              {t.language}
              <input className={field} value={form.languageCode} maxLength={2} onChange={(e) => setForm({ ...form, languageCode: e.target.value.toLowerCase() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.languageHint}</span>
            </label>
            <label className={label}>
              {t.currency}
              <input className={field} value={form.currency} maxLength={3} onChange={(e) => setForm({ ...form, currency: e.target.value.toUpperCase() })} />
              <span className="font-normal text-caption text-p4a-muted">{t.currencyHint}</span>
            </label>
            <label className={label}>
              {c.order}
              <input className={field} type="number" min={0} max={9999} value={form.sortOrder} onChange={(e) => setForm({ ...form, sortOrder: Number(e.target.value) })} />
            </label>
            <label className={label}>
              {t.languageSkill}
              <select className={field} value={form.languageSkillKey ?? ""} onChange={(e) => setForm({ ...form, languageSkillKey: e.target.value || null, minLanguageLevel: e.target.value ? form.minLanguageLevel : null })}>
                <option value="">{t.noSkill}</option>
                {languageSkills.map((s) => <option key={s.key} value={s.key}>{s.name}</option>)}
              </select>
              <span className="font-normal text-caption text-p4a-muted">{t.hintLanguageSkill}</span>
            </label>
            <label className={label}>
              {t.minLevel}
              <select className={field} value={form.minLanguageLevel ?? ""} disabled={!form.languageSkillKey}
                onChange={(e) => setForm({ ...form, minLanguageLevel: e.target.value ? Number(e.target.value) : null })}>
                <option value="">{t.anyLevel}</option>
                {levelsOf(form.languageSkillKey).map((l) => <option key={l.level} value={l.level}>{l.name}</option>)}
              </select>
              <span className="font-normal text-caption text-p4a-muted">{t.hintMinLevel}</span>
            </label>
          </div>
          <FlagField name={t.activeLabel} checked={form.active} onChange={(v) => setForm({ ...form, active: v })} />
          {marketProblem ? <p className="text-small text-p4a-error">{marketProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {week ? (
        <FormDialog key={week.opened} title={`${t.sectionHours}: ${week.market === "*" ? t.defaultRow : week.market}`} intro={t.hintHours}
          onSave={saveWeek} onClose={() => setWeek(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-[4rem_1fr] items-center gap-x-4 gap-y-2" data-testid="hours-week">
            {WEEKDAYS.map((d, i) => (
              <label key={d} className="contents text-small font-semibold">
                <span>{days[d - 1]}</span>
                <input className={field} value={week.texts[i]} placeholder={t.closed} maxLength={120}
                  onChange={(e) => setWeek({ ...week, texts: week.texts.map((x, j) => (j === i ? e.target.value : x)) })} />
              </label>
            ))}
          </div>
          {weekProblem ? <p className="text-small text-p4a-error">{weekProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {aliasOpen !== null ? (
        <FormDialog key={aliasOpen} title={t.addAlias} onSave={saveAlias} onClose={() => setAliasOpen(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.alias}
              <input className={field} value={alias.text} maxLength={100} onChange={(e) => setAlias({ ...alias, text: e.target.value })} />
            </label>
            <label className={label}>
              {t.aliasMarket}
              <select className={field} value={alias.code} onChange={(e) => setAlias({ ...alias, code: e.target.value })}>
                {data.markets.map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
              </select>
            </label>
          </div>
          {(() => {
            const holder = aliasHolder(alias.text);
            return holder && holder.code !== alias.code ? <p className="text-small text-p4a-muted">{t.aliasTaken.replace("{market}", holder.code)}</p> : null;
          })()}
          {aliasProblem ? <p className="text-small text-p4a-error">{aliasProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}

      {holidayOpen !== null ? (
        <FormDialog key={holidayOpen} title={t.addHoliday} onSave={saveHoliday} onClose={() => setHolidayOpen(null)} busy={state.kind === "saving"} saveLabel={c.save} cancelLabel={c.cancel}>
          <div className="grid grid-cols-2 gap-4">
            <label className={label}>
              {t.day}
              <input className={field} type="date" value={holiday.day} onChange={(e) => setHoliday({ ...holiday, day: e.target.value })} />
            </label>
            <label className={label}>
              {t.holidayMarket}
              <select className={field} value={holiday.market} onChange={(e) => setHoliday({ ...holiday, market: e.target.value })}>
                <option value="*">{t.everyMarket}</option>
                {data.markets.map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
              </select>
            </label>
            <label className={`${label} col-span-2`}>
              {t.holidayName}
              <input className={field} value={holiday.name} maxLength={100} onChange={(e) => setHoliday({ ...holiday, name: e.target.value })} />
            </label>
          </div>
          {holidayProblem ? <p className="text-small text-p4a-error">{holidayProblem}</p> : null}
          <SaveNote state={state} c={c} />
        </FormDialog>
      ) : null}
    </>
  );
}
