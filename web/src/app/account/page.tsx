import Link from "next/link";
import { Shell } from "@/components/Shell";
import { Badge, Card, Notice, PageTitle } from "@/components/primitives";
import { data, dataIsMock, type PersonSkill, type SkillDimension } from "@/lib/data";
import { resolve } from "../access";

const DIMENSIONS: SkillDimension[] = ["language", "work_type", "channel"];

/**
 * My account (slice 4(a), addition 0005b): the person's own details as the Workspace holds them,
 * read only. Opened from the name in the top bar, for everyone with access; the database answers
 * the caller's own row only (cma.my_profile takes no user id). The clock and the hours stay on My
 * day and My hours; this page links there and states the forgotten clock-out rule as the scheduler
 * applies it (migration 0005a). No ids in other systems: the sign-in id is never shown again. Since
 * 16 October 2026 (backlog CMA-019) a card says in plain words what the role allows: the person's
 * permission keys through a copy map, an unknown key as the key; while an admin previews a role it is
 * the narrowed set, and the banner above says why.
 */
export default async function MyAccountPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.account;
  const p = await data().getMyProfile(me);
  const hasClock = me.permissions.includes("workday.own");
  const dimensionLabel: Record<SkillDimension, string> = { language: t.languages, work_type: t.workTypes, channel: t.channels };
  const byDimension = DIMENSIONS.map((d) => ({ dimension: d, skills: p.skills.filter((s) => s.dimension === d) })).filter((g) => g.skills.length > 0);
  // "allow.<permission key>" in the copy; an unknown key is shown as the key
  const names: Record<string, string> = t;
  const allows = [...new Set(me.permissions)].sort();

  return (
    <Shell copy={copy} me={me} active="account">
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <div className="grid max-w-5xl grid-cols-2 gap-6">
        <Card title={t.details}>
          <dl className="grid grid-cols-[9rem_1fr] gap-x-4 gap-y-3 text-body">
            <dt className="text-p4a-muted">{t.name}</dt>
            <dd className="font-semibold">{p.displayName}</dd>
            <dt className="text-p4a-muted">{t.email}</dt>
            <dd className="break-all">{p.email}</dd>
            <dt className="text-p4a-muted">{t.employer}</dt>
            <dd>{p.organisationName || <span className="text-p4a-muted">{t.noEmployer}</span>}</dd>
            <dt className="text-p4a-muted">{t.role}</dt>
            <dd>{p.roleName ?? <span className="text-p4a-muted">{t.noRole}</span>}</dd>
            <dt className="text-p4a-muted">{t.timeZone}</dt>
            <dd>{p.timeZone}</dd>
          </dl>
        </Card>

        <Card title={t.teamsAndSkills}>
          <dl className="grid grid-cols-[9rem_1fr] gap-x-4 gap-y-3 text-body">
            <dt className="text-p4a-muted">{t.teams}</dt>
            <dd className="flex flex-wrap gap-2">
              {p.teams.length > 0
                ? p.teams.map((team) => <Badge key={team.key} tone="info">{team.name}</Badge>)
                : <span className="text-p4a-muted">{t.noTeams}</span>}
            </dd>
            {byDimension.map((g) => (
              <SkillRow key={g.dimension} label={dimensionLabel[g.dimension]} skills={g.skills} />
            ))}
            {byDimension.length === 0 ? (
              <>
                <dt className="text-p4a-muted">{copy.team.skills}</dt>
                <dd className="text-p4a-muted">{t.noSkills}</dd>
              </>
            ) : null}
          </dl>
        </Card>

        <Card title={t.time} className="col-span-2">
          <p className="text-body">{p.timeKept ? t.timeKept : t.timeNotKept}</p>
          {p.timeKept ? <p className="mt-2 text-small text-p4a-muted">{t.forgottenRule}</p> : null}
          {hasClock ? (
            <div className="mt-4 flex gap-6">
              <Link href="/day" className="font-semibold text-p4a-deepblue hover:underline">{t.openMyDay}</Link>
              <Link href="/hours" className="font-semibold text-p4a-deepblue hover:underline">{t.openMyHours}</Link>
            </div>
          ) : null}
        </Card>

        <Card title={t.allows} className="col-span-2">
          <p className="-mt-2 mb-4 text-caption text-p4a-grey">{t.allowsIntro}</p>
          {allows.length === 0 ? (
            <p className="text-body text-p4a-muted">{t.allowsNone}</p>
          ) : (
            <ul className="grid grid-cols-2 gap-x-6 gap-y-2 text-body" data-testid="permissions-list">
              {allows.map((key) => (
                <li key={key} className="flex items-start gap-3">
                  <span aria-hidden="true" className="mt-2 h-2 w-2 shrink-0 rounded-full bg-p4a-deepblue" />
                  <span>{names[`allow.${key}`] ?? key}</span>
                </li>
              ))}
            </ul>
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

/** One dimension's skills: a level shown as "Name · Level", a held skill by its name alone */
function SkillRow({ label, skills }: { label: string; skills: PersonSkill[] }) {
  return (
    <>
      <dt className="text-p4a-muted">{label}</dt>
      <dd className="flex flex-wrap gap-2">
        {skills.map((s) => (
          <Badge key={s.key} tone="neutral">{s.levelName ? `${s.name} · ${s.levelName}` : s.name}</Badge>
        ))}
      </dd>
    </>
  );
}
