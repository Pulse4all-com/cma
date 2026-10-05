import Link from "next/link";
import { Shell } from "@/components/Shell";
import { Card, Keycap, PageTitle } from "@/components/primitives";
import { data } from "@/lib/data";
import { dateKeyInZone } from "@/lib/time";
import { resolve } from "../access";

// Log out = end the workday + end the IAP session. The confirm is a plain form
// POST to /logout/end: a full-page navigation, so the browser follows IAP's
// cookie-clearing redirect itself (a client-side action could not).
export default async function LogOutPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const today = await data().getWorkday(me, dateKeyInZone(new Date(), me.timeZone));
  const dayOpen = today?.status === "working";

  return (
    <Shell copy={copy} me={me} active="my-day">
      <PageTitle>{copy.logOut.title}</PageTitle>
      <Card>
        <p className="text-body">{dayOpen ? copy.logOut.body : copy.logOut.bodyDayEnded}</p>
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
