import Link from "next/link";
import { ClockInCard } from "@/components/ClockInCard";
import { Swatch } from "@/components/DashboardCharts";
import { Shell } from "@/components/Shell";
import { Badge, Card, Notice } from "@/components/primitives";
import { agentGroupOf } from "@/lib/dashboard";
import { attentionLines, FOLLOW_UP_SUMMARY_PERMISSIONS, MY_FOLLOW_UP_PERMISSIONS, type AttentionLine } from "@/lib/follow-up";
import { workedSeconds } from "@/lib/live";
import {
  data, dataIsMock, type AppLink, type FollowUpSummary, type InboundNow, type MyFollowUp, type MyMessages, type MyRosterDay, type TeamHours,
  type WorkStatus, type Workday,
} from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { cellLabel } from "@/lib/roster";
import type { Copy, Locale } from "@/lib/copy";
import { addDays, dateKeyInZone, fmtDate, fmtMinutes, fmtTime, hourInZone } from "@/lib/time";
import { resolve } from "./access";

/** The to-do line looks back this many days, today excluded */
const TODO_DAYS = 31;
/** The Updates card shows this many of the latest messages */
const UPDATES_SHOWN = 5;

/**
 * Welcome (increment e, 7 October 2026): the landing page for everyone with a role, built as
 * blocks per permission. A visit opens nothing; Clock in is an action on the card. The blocks:
 * updates for everyone (empty until Messaging, migration 0006), Needs attention for people holding
 * workday.team, monitoring.live or performance.team (since addition 0008o, in place of the to-do line:
 * the days not clocked out, the leads past the target, the tickets at risk or over their response time,
 * the tasks overdue, the missed callers not called back; counts and links only), a Reports block for
 * performance.team (the one view of all KPIs later, Roadmap step 9), the Clock in card for workday.own,
 * Waiting for you for leads.accept or workday.own (the person's own leads, tickets and tasks, 0008o), and
 * the tenant's app links. Staff data only.
 */
export default async function WelcomePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.welcome;
  const now = new Date();
  const today = dateKeyInZone(now, me.timeZone);
  const hasClock = me.permissions.includes("workday.own");
  const hasTeam = me.permissions.includes("workday.team");
  const hasReports = me.permissions.includes("performance.team");
  const hasRoster = me.permissions.includes("roster.view");
  const hasLive = me.permissions.includes("monitoring.live");
  const hasAttention = holdsAny(me, FOLLOW_UP_SUMMARY_PERMISSIONS);
  const hasOwn = holdsAny(me, MY_FOLLOW_UP_PERMISSIONS);

  // One read per block the person may see; reading never opens a day
  const [workday, statuses, team, links, roster, inbox, summary, inbound, mine] = await Promise.all([
    hasClock ? data().getWorkday(me, today) : Promise.resolve(null),
    hasClock ? data().listStatuses(me) : Promise.resolve([] as WorkStatus[]),
    hasTeam ? data().getTeamHours(me, { from: addDays(today, -TODO_DAYS), to: addDays(today, -1) }, null) : Promise.resolve(null),
    data().listAppLinks(me),
    hasRoster ? data().getMyRoster(me, { from: today, to: today }) : Promise.resolve([] as MyRosterDay[]),
    // The latest messages for the Updates card (migration 0008); listing sets their delivered time, reading is the person's own click
    data().listMyMessages(me, null, UPDATES_SHOWN),
    // Needs attention and Waiting for you (addition 0008o): counts for the team, the person's own rows
    hasAttention ? data().getFollowUpSummary(me) : Promise.resolve(null),
    hasLive ? data().getInboundNow(me) : Promise.resolve(null),
    hasOwn ? data().getMyFollowUp(me) : Promise.resolve(null),
  ]);
  // The shift sentence the greeting waited for (migration 0005): from the published roster only
  const todayRoster = roster[0] ?? null;
  const shiftLine = !hasRoster || !todayRoster ? null
    : !todayRoster.isPublished ? t.rosterNotPublished
    : todayRoster.kind === "shift" ? t.shiftToday.replace("{shift}", cellLabel({ kind: "shift", start: todayRoster.start, end: todayRoster.end, absenceName: null }))
    : todayRoster.kind === "absence" ? t.absenceToday.replace("{absence}", todayRoster.absenceName ?? "")
    : t.noShiftToday;

  const hour = hourInZone(now, me.timeZone);
  const greeting = (hour < 12 ? t.morning : hour < 18 ? t.afternoon : t.evening).replace("{name}", me.displayName);

  return (
    <Shell copy={copy} me={me} active="welcome">
      <h1 className="text-title font-bold text-p4a-heading">{greeting}</h1>
      <p className="mt-1 text-body text-p4a-muted">
        {fmtDate(today, me.locale)}
        {shiftLine ? <span data-testid="shift-line">{` · ${shiftLine}`}</span> : null}
      </p>

      <div className="mt-8 grid grid-cols-[1fr_18rem] gap-6">
        <div className="flex flex-col gap-6">
          <UpdatesBlock inbox={inbox} timeZone={me.timeZone} locale={me.locale} copy={copy} />
          {summary ? <AttentionBlock summary={summary} team={team} inbound={inbound} copy={copy} /> : null}
          {hasReports ? (
            <Card title={t.reports}>
              <p className="text-body">{t.reportsBody}</p>
              <Link href="/reports/dashboard" className="mt-3 inline-block font-semibold text-p4a-deepblue hover:underline">
                {t.openDashboard}
              </Link>
            </Card>
          ) : null}
        </div>

        <div className="flex flex-col gap-6">
          {hasClock ? (
            <DayBlock workday={workday} statuses={statuses} timeZone={me.timeZone} locale={me.locale} now={now} copy={copy} />
          ) : null}
          {mine ? <WaitingBlock mine={mine} copy={copy} /> : null}
          {links.length > 0 ? <AppLinks links={links} copy={copy} /> : null}
        </div>
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}

/** The person's own day: Clock in when there is none, the open day's state, or the ended day */
function DayBlock({
  workday, statuses, timeZone, locale, now, copy,
}: {
  workday: Workday | null;
  statuses: WorkStatus[];
  timeZone: string;
  locale: Locale;
  now: Date;
  copy: Copy;
}) {
  const t = copy.welcome;
  if (!workday) {
    const defaultStatus = statuses.find((s) => s.isDefault);
    return <ClockInCard defaultStatusName={defaultStatus?.name ?? ""} copy={copy} />;
  }
  if (workday.status === "ended") {
    return (
      <Card>
        <Badge tone="neutral">{t.dayEnded}</Badge>
        <dl className="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-small">
          <dt className="text-p4a-muted">{t.clockedInAt}</dt>
          <dd className="tabular">{fmtTime(workday.startedAt, timeZone, locale)}</dd>
          <dt className="text-p4a-muted">{t.clockedOutAt}</dt>
          <dd className="tabular">{workday.endedAt ? fmtTime(workday.endedAt, timeZone, locale) : ""}</dd>
        </dl>
      </Card>
    );
  }
  const current = statuses.find((s) => s.key === workday.statusKey);
  // The running stretch stops at the day's end (the workday window, 0008b)
  const workedMinutes = Math.floor(workedSeconds(workday.clock, now.getTime(), workday.dayEndsAt) / 60);
  return (
    <Card>
      <div className="flex items-center gap-3">
        <Badge tone="info">{t.clockedIn}</Badge>
        {current ? (
          <span className="inline-flex items-center gap-2 text-small">
            <Swatch group={agentGroupOf(current)} />
            {current.name}
          </span>
        ) : workday.statusName ? (
          // A status no longer in the choosable list: its name as stored, no colour (no flags here)
          <span className="text-small">{workday.statusName}</span>
        ) : null}
      </div>
      <p className="mt-4 text-small text-p4a-muted">
        {t.clockedInAt} <span className="tabular text-p4a-body">{fmtTime(workday.startedAt, timeZone, locale)}</span>
        {" · "}
        <span className="tabular text-p4a-body">{fmtMinutes(workedMinutes)}</span> {t.workedSoFar}
      </p>
      <Link href="/day" className="mt-4 inline-block font-semibold text-p4a-deepblue hover:underline">
        {t.openMyDay}
      </Link>
    </Card>
  );
}

/** The latest messages, unread ones marked; the inbox has the rest (migration 0008) */
function UpdatesBlock({ inbox, timeZone, locale, copy }: { inbox: MyMessages; timeZone: string; locale: Locale; copy: Copy }) {
  const t = copy.welcome;
  const m = copy.messages;
  const more = inbox.unreadCount - inbox.messages.filter((x) => x.readAt === null).length;
  const fmt = new Intl.DateTimeFormat(locale === "nl" ? "nl-NL" : "en-GB", { timeZone, hour: "2-digit", minute: "2-digit" });
  return (
    <Card title={t.updates}>
      {inbox.messages.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.updatesEmpty}</p>
      ) : (
        <ul className="flex flex-col gap-2" data-testid="updates-list">
          {inbox.messages.map((x) => (
            <li key={x.id} className="flex items-start gap-3 text-body">
              <span aria-hidden="true" className={`mt-2 h-2 w-2 shrink-0 rounded-full ${x.readAt === null ? "bg-p4a-deepblue" : "bg-p4a-border"}`} />
              <span className="min-w-0 flex-1">
                <span className={x.readAt === null ? "font-semibold text-p4a-heading" : ""}>{x.title}</span>
                {x.body ? <span className="text-p4a-muted"> · {x.body}</span> : null}
              </span>
              <span className="shrink-0 text-caption text-p4a-grey tabular">{fmt.format(new Date(x.createdAt))}</span>
            </li>
          ))}
        </ul>
      )}
      <p className="mt-3 flex items-center gap-3">
        <Link href="/messages" className="font-semibold text-p4a-deepblue hover:underline">{t.openMessages}</Link>
        {more > 0 ? <span className="text-small text-p4a-muted">{more === 1 ? t.updatesMoreOne : t.updatesMore.replace("{n}", String(more))}</span> : null}
        {inbox.unreadCount > 0 ? <Badge tone="info">{inbox.unreadCount === 1 ? m.unreadOne : m.unread.replace("{n}", String(inbox.unreadCount))}</Badge> : null}
      </p>
    </Card>
  );
}

/**
 * Needs attention (addition 0008o; before it Steam's "to do before today's shift"): one line per figure
 * with its count and a link to where it is acted on. The days not clocked out of the last 31 days come
 * from Team hours (workday.team only); the leads past the target, the tickets at risk or over their
 * response time and the tasks overdue from cma.follow_up_summary; the missed callers not called back from
 * the Live board's read (monitoring.live, a tenant with telephony). Counts only, no name.
 */
function AttentionBlock({ summary, team, inbound, copy }: { summary: FollowUpSummary; team: TeamHours | null; inbound: InboundNow | null; copy: Copy }) {
  const t = copy.welcome;
  const lines = attentionLines(summary,
    team ? team.days.filter((d) => d.needsCorrection).length : null,
    inbound && inbound.telephony ? inbound.callbacks.length + inbound.anonymousCount : null);
  const text = (l: AttentionLine): string => {
    const one = l.count === 1;
    const n = String(l.count);
    switch (l.key) {
      case "daysNotEnded": return one ? t.attentionDaysOne : t.attentionDays.replace("{n}", n);
      case "leadsPastTarget": return one ? t.attentionLeadsOne : t.attentionLeads.replace("{n}", n);
      case "ticketsAtRiskOrBreached": return one ? t.attentionTicketsOne : t.attentionTickets.replace("{n}", n);
      case "tasksOverdue": return one ? t.attentionTasksOne : t.attentionTasks.replace("{n}", n);
      case "missedCallbacks": return one ? t.attentionMissedOne : t.attentionMissed.replace("{n}", n);
    }
  };
  return (
    <Card title={t.attention}>
      <p className="-mt-1 mb-3 text-caption text-p4a-grey">{t.attentionIntro}</p>
      <ul className="flex flex-col gap-2" data-testid="needs-attention">
        {lines.map((l) => (
          <li key={l.key} className="flex items-center gap-3 text-body">
            <Badge tone={l.count === 0 ? "success" : "warning"}>{l.count}</Badge>
            <Link href={l.href} className="font-semibold text-p4a-deepblue hover:underline">{text(l)}</Link>
          </li>
        ))}
      </ul>
    </Card>
  );
}

/** Waiting for you (addition 0008o): how much of the follow-up is the person's own, and the page with the rows */
function WaitingBlock({ mine, copy }: { mine: MyFollowUp; copy: Copy }) {
  const t = copy.welcome;
  const n = mine.leads.length + mine.tickets.length + mine.tasks.length;
  const line = n === 0 ? t.waitingNone
    : t.waitingLine.replace("{leads}", String(mine.leads.length)).replace("{tickets}", String(mine.tickets.length)).replace("{tasks}", String(mine.tasks.length));
  return (
    <Card title={t.waitingForYou}>
      <p className="flex items-center gap-3 text-body" data-testid="waiting-for-you">
        <Badge tone={n === 0 ? "success" : "info"}>{n}</Badge>
        {line}
      </p>
      <Link href="/me/follow-up" className="mt-3 inline-block font-semibold text-p4a-deepblue hover:underline">
        {t.openWaiting}
      </Link>
    </Card>
  );
}

/** The tenant's app links, already filtered by the database to what this person may see */
function AppLinks({ links, copy }: { links: AppLink[]; copy: Copy }) {
  const t = copy.welcome;
  return (
    <Card title={t.apps}>
      <ul className="flex flex-col gap-2">
        {links.map((l) => (
          <li key={l.key}>
            <a
              href={l.address}
              target="_blank"
              rel="noopener noreferrer"
              className="flex h-10 items-center justify-between rounded-button border border-p4a-deepblue px-4 font-semibold text-p4a-deepblue no-underline hover:bg-p4a-bgblue"
            >
              {l.label}
              <span aria-hidden="true">↗</span>
            </a>
          </li>
        ))}
      </ul>
      <p className="mt-3 text-caption text-p4a-grey">{t.appsHint}</p>
    </Card>
  );
}
