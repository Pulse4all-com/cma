import { LiveBoard, type BoardRow } from "@/components/LiveBoard";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { employersOf, liveRows, tiles } from "@/lib/live";
import { dateKeyInZone, fmtDate, fmtTime, fmtZoneShort, sameOffset } from "@/lib/time";
import { resolve } from "../../access";

/**
 * Live board (Live, first page of the Live group): who is on the clock right now, in which status
 * and since when, with a tile per group. Shown to people holding monitoring.live (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again on
 * every read (CMA06). Today only, Postgres only (the realtime service comes later): the page
 * reads once and the client re-reads it every 10 seconds while the tab is visible. Staff data,
 * never customer data, and no ranking.
 */
export default async function LiveBoardPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.live;

  if (!me.permissions.includes("monitoring.live")) {
    return (
      <Shell copy={copy} me={me} active="live-board">
        <PageTitle>{t.title}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{t.noPermissionTitle}</h2>
          <p className="mt-2 text-body">{t.noPermissionBody}</p>
        </Card>
      </Shell>
    );
  }

  const now = await data().getTeamNow(me);
  const rows = liveRows(now.people);
  const viewerZone = me.timeZone;
  const board: BoardRow[] = rows.map(({ person, group }) => ({
    userId: person.userId,
    displayName: person.displayName,
    organisationKey: person.organisationKey ?? "",
    organisationName: person.organisationName,
    group,
    statusName: person.status?.name ?? null,
    statusActive: person.status?.isActive ?? true,
    statusSince: person.day?.statusSince ?? null,
    // The clock's inputs; an ended day has nothing running, so its figure stands still
    clock: person.day?.clock ?? null,
    // Times in the person's own zone, as Team hours shows them, with the zone's short name when
    // its clock differs from the viewer's (Madrid and Amsterdam share one, London does not)
    inLabel: person.day ? fmtTime(person.day.startedAt, person.timeZone, me.locale) : null,
    outLabel: person.day?.endedAt ? fmtTime(person.day.endedAt, person.timeZone, me.locale) : null,
    zoneLabel: person.day && !sameOffset(person.day.startedAt, person.timeZone, viewerZone)
      ? fmtZoneShort(person.day.startedAt, person.timeZone, me.locale) : null,
  }));

  return (
    <Shell copy={copy} me={me} active="live-board" wide>
      <PageTitle>
        {t.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(dateKeyInZone(new Date(), me.timeZone), me.locale)}</span>
      </PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      {rows.length === 0 ? (
        <Card>
          <p className="text-body text-p4a-muted">{t.noPeople}</p>
        </Card>
      ) : (
        <LiveBoard
          rows={board}
          tiles={tiles(rows, now.statusFlags)}
          employers={employersOf(rows)}
          copy={copy}
        />
      )}

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
