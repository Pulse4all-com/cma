import { Shell } from "@/components/Shell";
import { Card, PageTitle } from "@/components/primitives";
import { resolve } from "../access";

export default async function MyHoursPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  return (
    <Shell copy={copy} me={me} active="my-hours">
      <PageTitle>{copy.nav.myHours}</PageTitle>
      <Card>
        <p className="text-body">{copy.myDay.comingNext}</p>
      </Card>
    </Shell>
  );
}
