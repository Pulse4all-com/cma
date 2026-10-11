import Link from "next/link";
import { redirect } from "next/navigation";
import { MessageComposer } from "@/components/MessageComposer";
import { Shell } from "@/components/Shell";
import { Badge, Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type SkillInfo, type TeamInfo, type TeamPerson } from "@/lib/data";
import { fmtSeconds } from "@/lib/messages";
import { addDays, dateKeyInZone } from "@/lib/time";
import { resolve } from "../../access";

/** The sent list looks back this many days */
const SENT_DAYS = 30;

/**
 * Send a message (migration 0008), for messages.send: the composer and the sent list of the last
 * 30 days with recipients, delivered, read and confirmed counts (cma.message_stats). The people
 * list for named recipients is the list of people whose time is kept (Team hours' list), when the
 * sender holds workday.team; teams and language skills come from the tenant's catalogs.
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
  const fmt = new Intl.DateTimeFormat(me.locale === "nl" ? "nl-NL" : "en-GB", { timeZone: me.timeZone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

  return (
    <Shell copy={copy} me={me} active="messages-send" wide>
      <PageTitle>{t.composeTitle}</PageTitle>
      <p className="mb-6 text-body">
        <Link href="/messages" className="font-semibold text-p4a-deepblue hover:underline">← {t.title}</Link>
      </p>
      <div className="grid grid-cols-[1fr_1fr] gap-6">
        <MessageComposer teams={teams as TeamInfo[]} languages={languages} people={people} copy={t} />
        <Card title={t.sentTitle}>
          {stats.length === 0 ? (
            <p className="text-body text-p4a-muted">{t.sentEmpty}</p>
          ) : (
            <table className="w-full text-small" data-testid="sent-table">
              <thead className="text-left text-p4a-muted">
                <tr>
                  <th className="h-9 pr-3 font-semibold">{t.colWhen}</th>
                  <th className="h-9 pr-3 font-semibold">{t.colTitle}</th>
                  <th className="h-9 pr-3 text-right font-semibold">{t.colRecipients}</th>
                  <th className="h-9 pr-3 text-right font-semibold">{t.colRead}</th>
                  <th className="h-9 pr-3 text-right font-semibold">{t.colAcknowledged}</th>
                  <th className="h-9 text-right font-semibold">{t.colMedian}</th>
                </tr>
              </thead>
              <tbody>
                {[...stats].reverse().map((s) => (
                  <tr key={s.id} className="border-t border-p4a-border">
                    <td className="py-2 pr-3 tabular text-p4a-muted">{fmt.format(new Date(s.createdAt))}</td>
                    <td className="py-2 pr-3">
                      <span className="flex items-center gap-2">
                        {s.byRule ? <Badge tone="info">{t.byRule}</Badge> : null}
                        {s.urgency === "urgent" ? <Badge tone="warning">{t.urgent}</Badge> : null}
                        <span>{s.title}</span>
                      </span>
                    </td>
                    <td className="py-2 pr-3 text-right tabular">{s.recipients}</td>
                    <td className="py-2 pr-3 text-right tabular">{s.read}</td>
                    <td className="py-2 pr-3 text-right tabular">{s.urgency === "urgent" ? s.acknowledged : "–"}</td>
                    <td className="py-2 text-right tabular">{fmtSeconds(s.medianSecondsToRead)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
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
