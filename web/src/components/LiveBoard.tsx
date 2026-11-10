"use client";

/**
 * The Live board's tiles, filters and rows. The rows come from the server (one read per page);
 * the two figures that change by the second, since and worked so far, tick here from the row's
 * instants, as the clock on My day does, so nothing is polled for the tick. The page re-reads
 * itself every 10 seconds while the tab is visible (LiveRefresh, since addition 0008i one poll for
 * the whole page) and once more when the tab comes back.
 *
 * Colours come from the flag groups in lib/dashboard, never from a status key or name, and every
 * colour mark sits next to its label. Filters are client-side (G for the group, E for the
 * employer) and survive a refresh: the server's rows change, the choice does not. Tiles and the
 * table follow docs/style/Pulse4all-Style.md 7.3 and 7.6 (padding 24px, Muted labels, zebra rows,
 * a hover row).
 *
 * The Live board's UX pass (10 November 2026): the groups are one panel of six as the call panels (the title, the people
 * shown, then a column per group, each a toggle that filters the table); the Employer column and filter show only when
 * the board's people have more than one employer (a contact center's board, addition 0008zv, has one), so every column
 * fits at 1280 px; the two figures that tick by the second are cells of their own on one shared clock, so the second
 * re-renders those cells, not the board.
 */
import { useState, useSyncExternalStore } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { BoardRow } from "@/lib/live-board";
import type { Group } from "@/lib/dashboard";
import type { Adherence } from "@/lib/roster";
import { type EmployerOption, type LiveGroup, type TeamOption, type Tile, fmtSeconds, secondsSince, workedSeconds } from "@/lib/live";
import { groupLabels, Swatch } from "./DashboardCharts";
import { Badge, Keycap } from "./primitives";

export type { BoardRow } from "@/lib/live-board";

/**
 * A one-second clock as an external store, one interval for every ticking cell: no setState in effects, no hydration
 * mismatch, and a second re-renders the cells that read it only
 */
const listeners = new Set<() => void>();
let clock: ReturnType<typeof setInterval> | null = null;
function subscribe(onTick: () => void) {
  listeners.add(onTick);
  if (clock === null) clock = setInterval(() => { for (const l of listeners) l(); }, 1000);
  return () => {
    listeners.delete(onTick);
    if (listeners.size === 0 && clock !== null) { clearInterval(clock); clock = null; }
  };
}
const nowSeconds = () => Math.floor(Date.now() / 1000) * 1000;
const serverNow = () => null;
const useNow = () => useSyncExternalStore(subscribe, nowSeconds, serverNow);

// Before the client clock starts (the server render) the since figure is left blank and the worked figure shows the
// closed part alone, as on My day
function Since({ at }: { at: string | null }) {
  const now = useNow();
  return <>{at && now !== null ? fmtSeconds(secondsSince(at, now)) : ""}</>;
}
function Worked({ clock: c }: { clock: BoardRow["clock"] }) {
  const now = useNow();
  return <>{c ? fmtSeconds(now === null ? c.closedSeconds : workedSeconds(c, now)) : ""}</>;
}

const isGroup = (g: LiveGroup): g is Group => g !== "clockedOut" && g !== "notClockedIn";

export function LiveBoard({
  rows,
  tiles,
  employers,
  teams,
  copy,
  locale,
}: {
  rows: BoardRow[];
  tiles: Tile[];
  employers: EmployerOption[];
  teams: TeamOption[];
  /** The board's words and the groups' (a slice, never the whole copy object: it rides in the page's payload) */
  copy: Pick<Copy, "live" | "dashboard">;
  /** The labels' language, so a long word breaks where the language breaks it */
  locale: Locale;
}) {
  const t = copy.live;
  const [group, setGroup] = useState<LiveGroup | "">("");
  const [employer, setEmployer] = useState("");
  const [team, setTeam] = useState("");

  const labels = groupLabels(copy);
  const flagLabel = (f: Adherence): string =>
    f === "late" ? t.late : f === "leftEarly" ? t.leftEarly : f === "expected" ? t.expected : f === "absent" ? t.absent : f === "unplanned" ? t.unplanned : t.onTime;
  const label = (g: LiveGroup): { label: string; hint: string } =>
    g === "clockedOut" ? { label: t.clockedOut, hint: t.clockedOutHint }
    : g === "notClockedIn" ? { label: t.notClockedIn, hint: t.notClockedInHint }
    : labels[g];

  const shown = rows.filter((r) =>
    (group === "" || r.group === group) && (employer === "" || r.organisationKey === employer) &&
    (team === "" || r.teams.some((x) => x.key === team)));
  // One employer (a contact center's board): the column and the filter would say the same thing on every row
  const byEmployer = employers.length > 1;
  const select =
    "h-10 min-w-56 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";
  const th = "px-3 py-2 font-semibold";

  return (
    <div className="flex flex-col gap-6">
      <section aria-labelledby="team-now" className="rounded-card border border-p4a-border bg-white p-6" data-testid="team-live">
        <div className="mb-4 flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <h2 id="team-now" className="text-panel font-semibold text-p4a-heading">{t.teamTitle}</h2>
          <p className="text-small text-p4a-muted" data-testid="team-shown">
            {t.peopleShown.replace("{n}", String(shown.length)).replace("{total}", String(rows.length))}
          </p>
        </div>
        {/* A group of toggle buttons: the name needs a role to be allowed on a div (the IT audit of 17 October 2026) */}
        <div className="grid grid-cols-6 divide-x divide-p4a-border" role="group" aria-label={t.group} data-testid="team-tiles">
          {tiles.map((tile) => (
            <div key={tile.group} className="flex min-w-0 px-2 first:pl-0 last:pr-0">
              <button
                type="button"
                aria-pressed={group === tile.group}
                title={label(tile.group).hint}
                onClick={() => setGroup(group === tile.group ? "" : tile.group)}
                className={[
                  "flex w-full flex-col rounded-input px-2 py-1 text-left",
                  group === tile.group ? "bg-p4a-bgblue ring-1 ring-p4a-deepblue" : "hover:bg-p4a-bgblue/50",
                ].join(" ")}
              >
                <p lang={locale} className="flex items-center gap-2 text-small text-p4a-muted [overflow-wrap:anywhere] hyphens-auto">
                  {isGroup(tile.group) ? <Swatch group={tile.group} /> : null}
                  {label(tile.group).label}
                </p>
                <p className="tabular mt-auto pt-1 text-title font-bold text-p4a-heading">{tile.count}</p>
              </button>
            </div>
          ))}
        </div>
      </section>

      <div className="flex items-end justify-between gap-4">
        <div className="flex items-end gap-4">
          <label className="flex flex-col gap-2 text-small font-semibold">
            <span className="flex items-center gap-2">
              {t.group} <Keycap>G</Keycap>
            </span>
            <select value={group} data-shortcut="g" onChange={(e) => setGroup(e.target.value as LiveGroup | "")} className={select}>
              <option value="">{t.allGroups}</option>
              {tiles.map((tile) => (
                <option key={tile.group} value={tile.group}>
                  {label(tile.group).label}
                </option>
              ))}
            </select>
          </label>
          {byEmployer ? (
            <label className="flex flex-col gap-2 text-small font-semibold">
              <span className="flex items-center gap-2">
                {t.employer} <Keycap>E</Keycap>
              </span>
              <select value={employer} data-shortcut="e" onChange={(e) => setEmployer(e.target.value)} className={select}>
                <option value="">{t.allEmployers}</option>
                {employers.map((e) => (
                  <option key={e.key} value={e.key}>
                    {e.name}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
          {teams.length > 0 ? (
            <label className="flex flex-col gap-2 text-small font-semibold">
              <span className="flex items-center gap-2">
                {t.team} <Keycap>T</Keycap>
              </span>
              <select value={team} data-shortcut="t" onChange={(e) => setTeam(e.target.value)} className={select}>
                <option value="">{t.allTeams}</option>
                {teams.map((x) => (
                  <option key={x.key} value={x.key}>
                    {x.name}
                  </option>
                ))}
              </select>
            </label>
          ) : null}
        </div>
      </div>

      {shown.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        // At 1280 px the nine columns can be wider than the main area: the table scrolls inside its own
        // box, never the page (as the report tables, addition 0008i)
        <div className="overflow-x-auto" data-testid="live-people-scroll" role="region" aria-label={t.title} tabIndex={0}>
        <table className="w-full border-collapse text-body leading-table">
          <thead>
            <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
              <th className={th}>{t.person}</th>
              {byEmployer ? <th className={th}>{t.employer}</th> : null}
              <th className={th}>{t.team}</th>
              <th className={th}>{t.shift}</th>
              <th className={th}>{t.status}</th>
              <th className={`${th} text-right`}>{t.since}</th>
              <th className={`${th} text-right`}>{t.clockedInAt}</th>
              <th className={`${th} text-right`}>{t.clockedOut}</th>
              <th className={`${th} text-right`}>{t.workedSoFar}</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.userId} className="h-10 border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                <td className="whitespace-nowrap px-3">{r.displayName}</td>
                {byEmployer ? <td className="whitespace-nowrap px-3 text-p4a-muted">{r.organisationName}</td> : null}
                <td className="whitespace-nowrap px-3 text-p4a-muted">{r.teams.map((x) => x.name).join(", ")}</td>
                <td className="whitespace-nowrap px-3">
                  <span className="flex items-center gap-2">
                    <span className={`tabular ${r.shift.label ? "" : "text-p4a-muted"}`}>
                      {!r.shift.published ? t.shiftNotPublished : r.shift.label ?? t.noShift}
                    </span>
                    {r.shift.flag && r.shift.flag !== "onTime" ? (
                      <Badge tone={r.shift.flag === "expected" || r.shift.flag === "unplanned" ? "info" : "warning"}>{flagLabel(r.shift.flag)}</Badge>
                    ) : null}
                  </span>
                </td>
                <td className="px-3">
                  <span className="flex items-center gap-2 whitespace-nowrap">
                    {isGroup(r.group) ? <Swatch group={r.group} /> : null}
                    {r.statusName ?? label(r.group).label}
                    {r.statusName && !r.statusActive ? <Badge tone="neutral">{t.inactive}</Badge> : null}
                  </span>
                </td>
                <td className="tabular whitespace-nowrap px-3 text-right"><Since at={r.statusSince} /></td>
                <td className="tabular whitespace-nowrap px-3 text-right">
                  {r.inLabel ?? ""}
                  {r.zoneLabel ? <span className="ml-1 text-caption text-p4a-grey">{r.zoneLabel}</span> : null}
                </td>
                <td className="tabular whitespace-nowrap px-3 text-right">{r.outLabel ?? ""}</td>
                <td className="tabular whitespace-nowrap px-3 text-right"><Worked clock={r.clock} /></td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
      )}
    </div>
  );
}
