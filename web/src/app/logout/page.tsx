import { Shell } from "@/components/Shell";
import { Card, PageTitle } from "@/components/primitives";
import { resolve } from "../access";

// Placeholder until the Log out screen lands: end the workday, then clear the
// IAP session with ?gcp-iap-mode=CLEAR_LOGIN_COOKIE
export default async function LogOutPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  return (
    <Shell copy={copy} me={me} active="my-day">
      <PageTitle>{copy.nav.logOut}</PageTitle>
      <Card>
        <p className="text-body">{copy.myDay.comingNext}</p>
      </Card>
    </Shell>
  );
}
