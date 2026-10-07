"use client";

/**
 * The Dashboard's person filter (P). The list holds the people with time in the period, so it
 * needs no team list and works for analytics, who hold performance.team but not workday.team.
 * Choosing a person keeps the period and loads the page for that person.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { PersonOption } from "@/lib/dashboard";
import { Keycap } from "./primitives";

export function DashboardFilter({
  people,
  person,
  query,
  copy,
}: {
  people: PersonOption[];
  /** The chosen person, or "" for everyone */
  person: string;
  /** The period part of the query string, kept when the filter changes */
  query: Record<string, string>;
  copy: Copy;
}) {
  const t = copy.dashboard;
  const router = useRouter();

  function filter(userId: string) {
    const qs = new URLSearchParams({ ...query, ...(userId ? { person: userId } : {}) });
    router.push(`/reports/dashboard?${qs.toString()}` as Route);
  }

  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.person} <Keycap>P</Keycap>
      </span>
      <select
        value={person}
        data-shortcut="p"
        onChange={(e) => filter(e.target.value)}
        className="h-10 min-w-64 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue"
      >
        <option value="">{t.everyone}</option>
        {people.map((p) => (
          <option key={p.userId} value={p.userId}>
            {p.displayName} · {p.organisationName}
          </option>
        ))}
      </select>
    </label>
  );
}
