import { Shell } from "@/components/Shell";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { dataIsMock } from "@/lib/data";
import { resolve } from "./access";

export default async function MyDayPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;

  return (
    <Shell copy={copy} me={me} active="my-day">
      <PageTitle>{copy.myDay.title}</PageTitle>
      <Card>
        <p className="text-body">{copy.myDay.comingNext}</p>
      </Card>
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
