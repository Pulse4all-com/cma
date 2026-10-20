import Link from "next/link";
import { redirect } from "next/navigation";
import { MessageComposer } from "@/components/MessageComposer";
import { Shell } from "@/components/Shell";
import { SentMessages } from "@/components/SentMessages";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type SkillInfo, type TeamInfo, type TeamPerson } from "@/lib/data";
import { WITHDRAW_PERMISSION } from "@/lib/messages";
import { addDays, dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/** The sent list looks back this many days */
const SENT_DAYS = 30;

/**
 * Send a message (migration 0008), for messages.send: the composer and the sent list of the last
 * 30 days with recipients, delivered, read and confirmed counts (cma.message_stats). The people
 * list for named recipients is the list of people whose time is kept (Team hours' list), when the
 * sender holds workday.team; teams and language skills come from the tenant's catalogs. A person
 * holding messages.withdraw deletes a sent message or alert for everyone from the list (addition 0008z).
 */
export default async function SendMessagePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  if (!me.permissions.includes("messages.send")) redirect("/messages");
  const t = copy.messages;
  const today = dateKeyInZone(new Date(), me.timeZone);
  const [teams, skills, people, stats] = await Promise.all([
    data().listTeams(me),
    data().listSkills(me),
    me.permissions.includes("workday.team") ? data().listTeamPeople(me) : Promise.resolve([] as TeamPerson[]),
    data().getMessageStats(me, { from: addDays(today, -SENT_DAYS), to: today }),
  ]);
  const languages = skills.filter((s: SkillInfo) => s.dimension === "language" && s.isActive);

  return (
    <Shell copy={copy} me={me} active="messages-send" wide>
      <PageTitle>{t.composeTitle}</PageTitle>
      <p className="mb-6 text-body">
        <Link href="/messages" className="font-semibold text-p4a-deepblue hover:underline">← {t.title}</Link>
      </p>
      <div className="grid grid-cols-[1fr_1fr] gap-6">
        <MessageComposer teams={teams as TeamInfo[]} languages={languages} people={people} copy={t} />
        <Card title={t.sentTitle}>
          <SentMessages stats={stats} copy={t} timeZone={me.timeZone} locale={me.locale} canWithdraw={me.permissions.includes(WITHDRAW_PERMISSION)} />
        </Card>
      </div>
      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
