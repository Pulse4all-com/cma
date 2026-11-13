"use client";

/**
 * The Dashboard's person filter (P). The list holds the people with time in the period, so it
 * needs no team list and works for analytics, who hold performance.team but not workday.team.
 * Choosing a person keeps the period and loads the page for that person, as a transition: the list says it is busy
 * and a dot beside the label pulses from the choice until the person's page is on the screen (a choice shows something
 * within 100 ms; the figures on the screen stay until the new ones are there).
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import type { PersonOption } from "@/lib/dashboard";
import { Keycap } from "./primitives";

export function DashboardFilter({
  people,
  person,
  query,
  labels,
}: {
  people: PersonOption[];
  /** The chosen person, or "" for everyone */
  person: string;
  /** The period part of the query string, kept when the filter changes */
  query: Record<string, string>;
  /** The filter's two labels. Not the copy catalog: a client component's props travel in the page, and the whole catalog was three quarters of this page's HTML (76 kB of it gzipped against 17 without) */
  labels: { person: string; everyone: string };
}) {
  const t = labels;
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function filter(userId: string) {
    const qs = new URLSearchParams({ ...query, ...(userId ? { person: userId } : {}) });
    startTransition(() => { router.push(`/reports/dashboard?${qs.toString()}` as Route); });
  }

  return (
    <label className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.person} <Keycap>P</Keycap>
        <span aria-hidden="true" data-filter-pending={pending ? "true" : undefined}
          className={`h-1.5 w-1.5 rounded-full bg-p4a-deepblue ${pending ? "animate-pulse opacity-80" : "opacity-0"}`} />
      </span>
      <select
        value={person}
        data-shortcut="p"
        aria-busy={pending || undefined}
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
