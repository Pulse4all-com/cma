import Image from "next/image";
import type { Metadata } from "next";
import { PrintButton } from "@/components/PrintButton";
import { data } from "@/lib/data";
import { cellLabel, headcountByDate, isoWeek, plannedMinutesByUser, weekDays } from "@/lib/roster";
import { addDays, dateKeyInZone, fmtDate, fmtMinutes, isDateKey, startOfWeek } from "@/lib/time";
import { resolve } from "../../../access";

export const metadata: Metadata = { title: "Roster" };

/**
 * The week on paper or as a file: the same grid as the planner, read-only, laid out for A4
 * landscape (Pulse4all-Style.md section 8: Sand or white page, Deep Blue headings, Background
 * Blue table header, a small footer with the date). No shell: the browser's print dialog does the
 * rest, and Save as file there makes it a PDF. The print view shows the current cells, with a
 * note when the week is a draft or has changed since the agents' version. Needs roster.manage.
 */
export default async function RosterPrintPage({ searchParams }: PageProps<"/roster/planner/print">) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.roster;
  const sp = await searchParams;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const weekStart = isDateKey(sp.week) ? startOfWeek(sp.week) : startOfWeek(today);
  const teamParam = typeof sp.team === "string" && sp.team !== "all" ? sp.team : null;

  if (!me.permissions.includes("roster.manage")) {
    return (
      <main className="min-h-full bg-white p-10 text-p4a-body">
        <h1 className="text-title font-bold text-p4a-heading">{t.noPermissionTitle}</h1>
        <p className="mt-2 text-body">{t.noPermissionBody}</p>
      </main>
    );
  }

  const week = await data().getRosterWeek(me, weekStart, teamParam);
  const days = weekDays(weekStart);
  const byKey = new Map(week.entries.map((e) => [`${e.userId}:${e.date}`, e]));
  const planned = plannedMinutesByUser(week.entries);
  const headcount = headcountByDate(week.entries);
  const h = week.header;
  const title = `${t.printTitle} · ${h.teamName ?? t.wholeTenant} · ${t.weekOf.replace("{n}", String(isoWeek(weekStart)))}`;
  const stamp = new Intl.DateTimeFormat(me.locale === "nl" ? "nl-NL" : "en-GB", { dateStyle: "medium", timeStyle: "short", timeZone: me.timeZone });
  const th = "border border-p4a-border px-2 py-1 text-left text-small font-semibold text-p4a-heading";
  const td = "border border-p4a-border px-2 py-1 align-top";

  return (
    <main className="min-h-full bg-white p-10 text-p4a-body print:p-0" data-testid="roster-print">
      <title>{`${title} ${weekStart}`}</title>
      <div className="mb-4 flex items-start justify-between gap-6 print:hidden">
        <p className="text-small text-p4a-muted">{t.printHint}</p>
        <PrintButton label={t.print} />
      </div>

      <header className="mb-6 flex items-end justify-between border-b border-p4a-deepblue pb-3">
        <div>
          <h1 className="text-title font-bold text-p4a-heading">{title}</h1>
          <p className="mt-1 text-body text-p4a-muted">
            {fmtDate(weekStart, me.locale)} – {fmtDate(addDays(weekStart, 6), me.locale)}
            {" · "}
            {h.status === "published"
              ? t.publishedAs.replace("{version}", String(h.version)).replace("{when}", h.publishedAt ? stamp.format(new Date(h.publishedAt)) : "").replace("{who}", h.publishedByName ?? "")
              : t.draft}
          </p>
          {h.status === "draft" ? <p className="mt-1 text-small text-p4a-warning">{t.printDraftNote}</p> : null}
          {h.changedSincePublish ? <p className="mt-1 text-small text-p4a-warning">{t.printChangedNote.replaceAll("{version}", String(h.version))}</p> : null}
        </div>
        <Image src="/brand/logo-blue.png" alt="Pulse4all" width={141} height={28} className="h-7 w-auto" unoptimized />
      </header>

      {week.people.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.noPeople}</p>
      ) : (
        <table className="w-full border-collapse text-body">
          <thead>
            <tr className="bg-p4a-bgblue">
              <th className={th}>{t.person}</th>
              {days.map((d) => (
                <th key={d} className={th}>{fmtDate(d, me.locale, "compact")}</th>
              ))}
              <th className={`${th} text-right`}>{t.planned}</th>
            </tr>
          </thead>
          <tbody>
            {week.people.map((p) => (
              <tr key={p.userId} className="odd:bg-p4a-offwhite">
                <td className={`${td} whitespace-nowrap`}>
                  <span className="font-semibold">{p.displayName}</span>
                  <span className="block text-caption text-p4a-grey">{p.organisationName}</span>
                </td>
                {days.map((d) => {
                  const e = byKey.get(`${p.userId}:${d}`) ?? null;
                  return (
                    <td key={d} className={`${td} tabular ${e?.kind === "absence" ? "text-p4a-muted" : ""}`}>
                      <span className="whitespace-nowrap">{cellLabel(e) || "–"}</span>
                      {e?.note ? <span className="block text-caption text-p4a-grey">{e.note}</span> : null}
                    </td>
                  );
                })}
                <td className={`${td} tabular whitespace-nowrap text-right`}>{fmtMinutes(planned.get(p.userId) ?? 0)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="text-small font-semibold text-p4a-heading">
              <td className={td}>{t.people}</td>
              {days.map((d) => (
                <td key={d} className={`${td} tabular`}>{headcount.get(d) ?? 0}</td>
              ))}
              <td className={td} />
            </tr>
          </tfoot>
        </table>
      )}

      <footer className="mt-6 flex items-center justify-between text-caption text-p4a-grey">
        <span>{copy.app.name} · {copy.app.tagline}</span>
        <span>{t.printedOn.replace("{date}", stamp.format(new Date()))}</span>
      </footer>
    </main>
  );
}
