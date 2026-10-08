"use client";

/**
 * The Live board's tiles, filters and rows. The rows come from the server (one read per page);
 * the two figures that change by the second, since and worked so far, tick here from the row's
 * instants, as the clock on My day does, so nothing is polled for the tick. The board re-reads
 * the page every 10 seconds while the tab is visible (router.refresh, the fallback until the
 * realtime service; README: Roadmap step 2) and once more when the tab comes back.
 *
 * Colours come from the flag groups in lib/dashboard, never from a status key or name, and every
 * colour mark sits next to its label. Filters are client-side (G for the group, E for the
 * employer) and survive a refresh: the server's rows change, the choice does not.
 */
import { useEffect, useState, useSyncExternalStore } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { Group } from "@/lib/dashboard";
import type { WorkdayClock } from "@/lib/data";
import { type EmployerOption, type LiveGroup, type TeamOption, type Tile, fmtSeconds, secondsSince, workedSeconds } from "@/lib/live";
import { groupLabels, Swatch } from "./DashboardCharts";
import { Badge, Keycap } from "./primitives";

/** One row, with its labels pre-formatted on the server in the person's zone and locale */
export interface BoardRow {
  userId: string;
  displayName: string;
  organisationKey: string;
  organisationName: string;
  group: LiveGroup;
  /** The current status; null without a day and once the day has ended */
  statusName: string | null;
  statusActive: boolean;
  statusSince: string | null;
  /** The clock's inputs; null without a day. An ended day has nothing running */
  clock: WorkdayClock | null;
  inLabel: string | null;
  outLabel: string | null;
  /** Short zone name when the person's zone differs from the viewer's */
  zoneLabel: string | null;
  /** The person's current teams (migration 0004), for the team filter and the Team column */
  teams: { key: string; name: string }[];
}

const REFRESH_MS = 10_000;

/** A one-second clock as an external store: no setState in effects, no hydration mismatch */
function subscribe(onTick: () => void) {
  const id = setInterval(onTick, 1000);
  return () => clearInterval(id);
}
const nowSeconds = () => Math.floor(Date.now() / 1000) * 1000;
const serverNow = () => null;

const isGroup = (g: LiveGroup): g is Group => g !== "clockedOut" && g !== "notClockedIn";

export function LiveBoard({
  rows,
  tiles,
  employers,
  teams,
  copy,
}: {
  rows: BoardRow[];
  tiles: Tile[];
  employers: EmployerOption[];
  teams: TeamOption[];
  copy: Copy;
}) {
  const t = copy.live;
  const router = useRouter();
  const now = useSyncExternalStore(subscribe, nowSeconds, serverNow);
  const [group, setGroup] = useState<LiveGroup | "">("");
  const [employer, setEmployer] = useState("");
  const [team, setTeam] = useState("");

  // The poll: every 10 seconds while visible, paused while hidden, once more on return
  useEffect(() => {
    let id: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (id === null) id = setInterval(() => router.refresh(), REFRESH_MS);
    };
    const stop = () => {
      if (id !== null) clearInterval(id);
      id = null;
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        router.refresh();
        start();
      } else {
        stop();
      }
    };
    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [router]);

  const labels = groupLabels(copy);
  const label = (g: LiveGroup): { label: string; hint: string } =>
    g === "clockedOut" ? { label: t.clockedOut, hint: t.clockedOutHint }
    : g === "notClockedIn" ? { label: t.notClockedIn, hint: t.notClockedInHint }
    : labels[g];

  const shown = rows.filter((r) =>
    (group === "" || r.group === group) && (employer === "" || r.organisationKey === employer) &&
    (team === "" || r.teams.some((x) => x.key === team)));
  // Before the client clock starts (the server render) the since figure is left blank and the
  // worked figure shows the closed part alone, as on My day
  const since = (r: BoardRow) =>
    r.statusSince && now !== null ? fmtSeconds(secondsSince(r.statusSince, now)) : "";
  const worked = (r: BoardRow) =>
    r.clock ? fmtSeconds(now === null ? r.clock.closedSeconds : workedSeconds(r.clock, now)) : "";
  const select =
    "h-10 min-w-56 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue";
  const th = "px-3 py-2 font-semibold";

  return (
    <div className="flex flex-col gap-6">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(11rem,1fr))] gap-4" aria-label={t.group}>
        {tiles.map((tile) => (
          <button
            key={tile.group}
            type="button"
            aria-pressed={group === tile.group}
            title={label(tile.group).hint}
            onClick={() => setGroup(group === tile.group ? "" : tile.group)}
            className={[
              "rounded-card border bg-white p-4 text-left",
              group === tile.group ? "border-p4a-deepblue" : "border-p4a-border hover:border-p4a-denim",
            ].join(" ")}
          >
            <p className="flex items-center gap-2 text-caption text-p4a-grey">
              {isGroup(tile.group) ? <Swatch group={tile.group} /> : null}
              {label(tile.group).label}
            </p>
            <p className="tabular mt-1 text-title font-bold text-p4a-heading">{tile.count}</p>
          </button>
        ))}
      </div>

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
        <p className="text-caption text-p4a-grey">
          {t.peopleShown.replace("{n}", String(shown.length)).replace("{total}", String(rows.length))} · {t.refreshHint}
        </p>
      </div>

      {shown.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        <table className="w-full border-collapse text-body">
          <thead>
            <tr className="bg-p4a-bgblue text-left text-small text-p4a-heading">
              <th className={th}>{t.person}</th>
              <th className={th}>{t.employer}</th>
              <th className={th}>{t.team}</th>
              <th className={th}>{t.status}</th>
              <th className={`${th} text-right`}>{t.since}</th>
              <th className={`${th} text-right`}>{t.clockedInAt}</th>
              <th className={`${th} text-right`}>{t.clockedOut}</th>
              <th className={`${th} text-right`}>{t.workedSoFar}</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <tr key={r.userId} className="h-10 border-b border-p4a-border odd:bg-white even:bg-p4a-offwhite">
                <td className="whitespace-nowrap px-3">{r.displayName}</td>
                <td className="whitespace-nowrap px-3 text-p4a-muted">{r.organisationName}</td>
                <td className="whitespace-nowrap px-3 text-p4a-muted">{r.teams.map((x) => x.name).join(", ")}</td>
                <td className="px-3">
                  <span className="flex items-center gap-2 whitespace-nowrap">
                    {isGroup(r.group) ? <Swatch group={r.group} /> : null}
                    {r.statusName ?? label(r.group).label}
                    {r.statusName && !r.statusActive ? <Badge tone="neutral">{t.inactive}</Badge> : null}
                  </span>
                </td>
                <td className="tabular whitespace-nowrap px-3 text-right">{since(r)}</td>
                <td className="tabular whitespace-nowrap px-3 text-right">
                  {r.inLabel ?? ""}
                  {r.zoneLabel ? <span className="ml-1 text-caption text-p4a-grey">{r.zoneLabel}</span> : null}
                </td>
                <td className="tabular whitespace-nowrap px-3 text-right">{r.outLabel ?? ""}</td>
                <td className="tabular whitespace-nowrap px-3 text-right">{worked(r)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
