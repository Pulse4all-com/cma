"use client";

/**
 * The filters of Reports → Forms (addition 0008p), next to the period bar: market (K), category (A) and form
 * (F); and in the answers card the question and the answer. The lists hold what the period's submissions
 * have (the categories from the tenant's catalog), so a chosen value without submissions stays in its list.
 * Choosing keeps the period and the grouping and loads the page with the filter; a new form clears the
 * question, a new question the answer. K, A and F are free on this page: the period bar holds Y, T, W, M
 * and C, the grouping G, the download X, the rail its digits and the top bar L. Category moved from Y to A
 * when the period bar gained Yesterday (26 October 2026).
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { FormCategory, FormsFilter } from "@/lib/data";
import { Keycap } from "./primitives";

const select = "h-10 w-44 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";

function href(query: Record<string, string | null>): Route {
  const qs = new URLSearchParams(Object.entries(query).filter((e): e is [string, string] => e[1] !== null && e[1] !== ""));
  return `/reports/forms?${qs.toString()}` as Route;
}

export function FormsFilters({ markets, categories, forms, filter, query, copy }: {
  /** Market codes, "unknown" for submissions without a market */
  markets: string[];
  categories: FormCategory[];
  forms: { key: string; name: string }[];
  filter: FormsFilter;
  /** The period and grouping part of the query string, kept when a filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.forms;
  const router = useRouter();
  const marketList = filter.market && !markets.includes(filter.market) ? [...markets, filter.market] : markets;
  const formList = filter.form && !forms.some((f) => f.key === filter.form) ? [...forms, { key: filter.form, name: filter.form.split(":").slice(1).join(":") }] : forms;
  const categoryList = [
    ...categories.map((c) => ({ code: c.code, name: c.name })),
    ...(filter.category && filter.category !== "none" && !categories.some((c) => c.code === filter.category) ? [{ code: filter.category, name: filter.category }] : []),
    { code: "none", name: t.noCategory },
  ];

  function go(next: FormsFilter) {
    router.push(href({ ...query, market: next.market, category: next.category, form: next.form }));
  }

  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="forms-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.marketFilter} <Keycap>K</Keycap></span>
        <select value={filter.market ?? ""} data-shortcut="k" data-testid="forms-market" className={select}
          onChange={(e) => go({ ...filter, market: e.target.value || null })}>
          <option value="">{t.allMarkets}</option>
          {marketList.map((m) => <option key={m} value={m}>{m === "unknown" ? copy.reports.unknownMarket : m}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.categoryFilter} <Keycap>A</Keycap></span>
        <select value={filter.category ?? ""} data-shortcut="a" data-testid="forms-category" className={select}
          onChange={(e) => go({ ...filter, category: e.target.value || null })}>
          <option value="">{t.allCategories}</option>
          {categoryList.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        <span className="flex items-center gap-2">{t.formFilter} <Keycap>F</Keycap></span>
        <select value={filter.form ?? ""} data-shortcut="f" data-testid="forms-form" className={`${select} w-64`}
          onChange={(e) => go({ ...filter, form: e.target.value || null })}>
          <option value="">{t.allForms}</option>
          {formList.map((f) => <option key={f.key} value={f.key}>{f.name}</option>)}
        </select>
      </label>
    </div>
  );
}

/** The answers' question and answer filters; the lists hold the questions and answers of the period's kept answers */
export function AnswerFilters({ fields, field, value, query, copy }: {
  /** Each question with its answers */
  fields: { field: string; values: string[] }[];
  field: string | null;
  value: string | null;
  /** The period, grouping and filters of the page, kept when a choice changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.forms;
  const router = useRouter();
  const fieldList = field && !fields.some((f) => f.field === field) ? [...fields, { field, values: value ? [value] : [] }] : fields;
  const values = fieldList.find((f) => f.field === field)?.values ?? [];
  const valueList = value && !values.includes(value) ? [...values, value] : values;
  return (
    <div className="flex flex-wrap items-end gap-4" data-testid="forms-answer-filters">
      <label className="flex flex-col gap-2 text-small font-semibold">
        {t.fieldFilter}
        <select value={field ?? ""} data-testid="forms-field" className={`${select} w-56`}
          onChange={(e) => router.push(href({ ...query, field: e.target.value || null, value: null }), { scroll: false })}>
          <option value="">{t.allFields}</option>
          {fieldList.map((f) => <option key={f.field} value={f.field}>{f.field}</option>)}
        </select>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        {t.valueFilter}
        <select value={value ?? ""} data-testid="forms-value" className={`${select} w-56`} disabled={field === null}
          onChange={(e) => router.push(href({ ...query, field, value: e.target.value || null }), { scroll: false })}>
          <option value="">{t.allValues}</option>
          {valueList.map((v) => <option key={v} value={v}>{v}</option>)}
        </select>
      </label>
    </div>
  );
}
