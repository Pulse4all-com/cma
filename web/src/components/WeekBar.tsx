/**
 * Previous week, this week, next week as plain links (P, W, N), with the week number and its
 * dates in the middle, so the week lives in the URL and the back button works. A server
 * component; the planner adds its team choice next to it.
 */
import Link from "next/link";
import type { ReactNode } from "react";
import type { Copy, Locale } from "@/lib/copy";
import { isoWeek } from "@/lib/roster";
import { addDays, fmtDate } from "@/lib/time";
import { Keycap } from "./primitives";

export function WeekBar({
  pathname,
  weekStart,
  thisWeek,
  copy,
  locale,
  keep = {},
  children,
}: {
  pathname: "/roster/planner" | "/schedule";
  weekStart: string;
  thisWeek: string;
  copy: Copy;
  locale: Locale;
  /** Other query values to carry along, such as the team */
  keep?: Record<string, string>;
  /** Extra controls at the right end of the bar */
  children?: ReactNode;
}) {
  const t = copy.roster;
  const link = (week: string, label: string, key: string, current: boolean) => (
    <Link
      href={{ pathname, query: { ...keep, week } }}
      aria-current={current ? "page" : undefined}
      data-shortcut={key.toLowerCase()}
      className={[
        "inline-flex h-10 items-center gap-2 rounded-button border px-4 text-body font-semibold",
        current ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
      ].join(" ")}
    >
      {label}
      <Keycap>{key}</Keycap>
    </Link>
  );
  return (
    <div className="mb-6 flex items-center justify-between gap-6">
      <nav aria-label={t.week} className="flex items-center gap-2">
        {link(addDays(weekStart, -7), t.previousWeek, "P", false)}
        {link(thisWeek, t.thisWeek, "W", weekStart === thisWeek)}
        {link(addDays(weekStart, 7), t.nextWeek, "N", false)}
        <span className="ml-4 text-body">
          <span className="font-semibold text-p4a-heading">{t.weekOf.replace("{n}", String(isoWeek(weekStart)))}</span>
          <span className="ml-2 text-p4a-muted">
            {fmtDate(weekStart, locale, "short")} – {fmtDate(addDays(weekStart, 6), locale)}
          </span>
        </span>
      </nav>
      {children}
    </div>
  );
}
