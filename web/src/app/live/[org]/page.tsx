import { notFound, redirect } from "next/navigation";
import { LiveBoardLive } from "@/components/LiveBoardLive";
import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock } from "@/lib/data";
import { boardOfOrganisation } from "@/lib/live";
import { dateKeyInZone, fmtDate } from "@/lib/time";
import { resolve } from "../../access";

/** The board's address before addition 0008zv: it opens the first contact center's board */
const FORMER_ADDRESS = "board";

/**
 * Live board (Live, first page of the Live group): who is on the clock right now, in which status
 * and since when, with a tile per group. Shown to people holding monitoring.live (supervisor,
 * manager and analytics in the default ladder); the database checks that permission again on
 * every read (CMA06). Today only, Postgres only (the realtime service comes later). Since night N06
 * (addition 0008zr's web) the page reads everything once, in one transaction (data().getLiveBoard), and
 * the client (LiveBoardLive) polls GET /api/v1/live/board every 10 seconds while the tab is visible and
 * updates the board from the answer: no page render per poll. Staff data, never customer data, and no
 * ranking. Since addition 0008i it opens with today's inbound tiles (InboundLive); the missed calls not
 * called back (MissedCallbacks) close the board since addition 0008z (Martin, 20 October 2026): line
 * names, codes and counts, never a number, a name or the caller's hash.
 *
 * Since addition 0008zv (Martin, 5 November 2026) one board per contact-center organisation, at /live/<key>: the
 * people, groups and statuses only of that organisation's people (lib/live boardOfOrganisation, here and in every
 * poll's ?organisation=<key>), the rail's item and the last breadcrumb its name; the inbound and missed-call parts and
 * the follow-up strip stay tenant-wide, the call parts captioned as covering all lines and the strip as covering the
 * whole business line. Without monitoring.live any address shows the no-permission card (the permission first, as the
 * API). A key that is no contact center of the person's tenant (an unknown organisation or one not flagged) renders the
 * not-found page; /live/board, the former address, opens the first contact center's board (unless an organisation is
 * keyed board, whose board it then is). The route keeps its loading boundary, so a click shows the skeleton at once;
 * the boundary sends 200 before the page decides, so the not-found page and the redirect are streamed with status 200
 * (a soft 404, accepted on Live to keep the skeleton: Martin, 5 November 2026).
 */
export default async function LiveBoardPage({ params }: { params: Promise<{ org: string }> }) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.live;
  const { org } = await params;

  // The permission first, as the API: without monitoring.live every board's address shows the same card, so nobody
  // without the board learns which keys are contact centers
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

  const center = me.contactCenters.find((c) => c.key === org);
  if (!center) {
    const first = me.contactCenters[0];
    if (org === FORMER_ADDRESS && first) redirect(`/live/${first.key}`);
    notFound();
  }
  const href = `/live/${center.key}` as const;

  // One read, one transaction: the team now, the memberships, today's shifts, the settings, inbound and follow-up;
  // then this contact center's people only
  const board = boardOfOrganisation(await data().getLiveBoard(me), center.key);
  // The board's words only (a slice of the copy object; the whole one weighed about 90 kB in every poll's page before)
  const liveCopy = { live: copy.live, hints: copy.hints, inbound: copy.inbound, reports: copy.reports, followUp: copy.followUp, dashboard: copy.dashboard };

  return (
    <Shell copy={copy} me={me} active="live-board" activeHref={href} wide>
      <PageTitle>
        {t.title}
        <span className="ml-3 text-small font-normal text-p4a-muted">{fmtDate(dateKeyInZone(new Date(), me.timeZone), me.locale)}</span>
      </PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <LiveBoardLive initial={board} organisation={center} viewer={{ locale: me.locale, timeZone: me.timeZone }} copy={liveCopy}
        canOpenMetrics={me.permissions.includes("tenant.configure")} />

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
