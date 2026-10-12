import Link from "next/link";
import { Shell } from "@/components/Shell";
import { Card, Keycap, Notice, PageTitle } from "@/components/primitives";
import { data } from "@/lib/data";
import { workedSeconds } from "@/lib/live";
import { dateKeyInZone, fmtMinutes, fmtTime } from "@/lib/time";
import { resolve } from "../access";

// Log out = end the workday + end the IAP session. The confirm is a plain form
// POST to /logout/end: a full-page navigation, so the browser follows IAP's
// cookie-clearing redirect itself (a client-side action could not).
export default async function LogOutPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const now = new Date();
  const today = await data().getWorkday(me, dateKeyInZone(now, me.timeZone));
  const dayOpen = today?.status === "working";
  // The clock's figures at this moment, so the person sees what logging out ends (11 October 2026)
  const workedMinutes = today ? Math.floor(workedSeconds(today.clock, now.getTime(), today.dayEndsAt) / 60) : 0;
  const clockLine = today && dayOpen
    ? copy.logOut.clockStops.replace("{start}", fmtTime(today.startedAt, me.timeZone, me.locale)).replace("{worked}", fmtMinutes(workedMinutes))
    : null;

  return (
    <Shell copy={copy} me={me} active="welcome">
      <PageTitle>{copy.logOut.title}</PageTitle>
      <Card>
        <p className="text-body">{dayOpen ? copy.logOut.body : copy.logOut.bodyDayEnded}</p>
        {clockLine ? (
          <div className="mt-4" data-testid="logout-clock-warning">
            <Notice tone="warning">{clockLine}</Notice>
          </div>
        ) : null}
        <form method="post" action="/logout/end" className="mt-6 flex items-center gap-3">
          <button
            type="submit"
            autoFocus
            className="inline-flex h-12 items-center gap-3 rounded-button bg-p4a-deepblue px-6 font-semibold text-white hover:bg-p4a-denim"
          >
            {copy.logOut.confirm}
            <Keycap>Enter</Keycap>
          </button>
          <Link
            href="/"
            data-shortcut="s"
            className="inline-flex h-12 items-center gap-3 rounded-button border border-p4a-deepblue px-6 font-semibold text-p4a-deepblue hover:bg-p4a-bgblue"
          >
            {copy.logOut.cancel}
            <Keycap>S</Keycap>
          </Link>
        </form>
      </Card>
    </Shell>
  );
}
