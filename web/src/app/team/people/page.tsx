import { InvitationsSection } from "@/components/InvitationsSection";
import type { InviteContext } from "@/components/InviteDialog";
import { Shell } from "@/components/Shell";
import { TeamDirectory } from "@/components/TeamDirectory";
import { Card, Notice, PageTitle } from "@/components/primitives";
import { config } from "@/lib/config";
import { copy as allCopy, t as copyFor, type Locale } from "@/lib/copy";
import { data, dataIsMock } from "@/lib/data";
import { holdsAny } from "@/lib/nav";
import { resolve } from "../../access";

/**
 * People (Team group, migration 0004): everyone of the tenant with role, employer, teams and
 * skills; add a person, change a role, teams, skills, active flag. Shown to people holding
 * users.manage_agents (agents, supervisors and other non-managing roles) or users.manage_all
 * (everyone); the database decides who is listed and who may be edited on every read and write
 * (CMA06). Staff data only, never customer data; a login id is written once and never read back.
 * Since addition 0008l: Invite (by work email, with a role within the caller's ceiling) next to Add a
 * person, and the Invitations section below the people; a link's token is shown only right after it is
 * made, never listed.
 */
export default async function PeoplePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.team;

  if (!holdsAny(me, ["users.manage_agents", "users.manage_all"])) {
    return (
      <Shell copy={copy} me={me} active="people">
        <PageTitle>{t.title}</PageTitle>
        <Card>
          <h2 className="text-panel font-semibold text-p4a-heading">{t.noPermissionTitle}</h2>
          <p className="mt-2 text-body">{t.noPermissionBody}</p>
        </Card>
      </Shell>
    );
  }

  // One transaction per read; the directory's own permission check decides who is listed
  const [people, roles, teams, skills, organisations, linked, invitations] = await Promise.all([
    data().listDirectory(me),
    data().listRoles(me),
    data().listTeams(me),
    data().listSkills(me),
    data().listOrganisations(me),
    data().getLinkedAccounts(me),
    data().listInvitations(me),
  ]);
  const maySetSkills = me.permissions.includes("skills.manage");
  // The mail's wording in every language of the copy, so the invitee's language is chosen in the dialog
  const invite: InviteContext = {
    roles, teams, skills, organisations, maySetSkills,
    mailCopy: Object.fromEntries((Object.keys(allCopy) as Locale[]).map((l) => [l, copyFor(l).invitationMail])),
    screenLocale: me.locale, inviterName: me.displayName, workspaceName: me.tenantName, timeZone: me.timeZone,
  };

  return (
    <Shell copy={copy} me={me} active="people" wide>
      <PageTitle>{t.title}</PageTitle>
      <p className="-mt-2 mb-6 max-w-3xl text-small text-p4a-muted">{t.intro}</p>

      <Card>
        <TeamDirectory
          people={people}
          roles={roles}
          teams={teams}
          skills={skills}
          organisations={organisations}
          meId={me.userId}
          maySetSkills={maySetSkills}
          // The sign-in provider the app runs with: google behind IAP, mock in dev (a data value, as stored)
          defaultLoginSystem={config.authMode === "iap" ? "google" : "mock"}
          linked={linked}
          invite={invite}
          copy={copy}
        />
      </Card>

      <div className="mt-6">
        <InvitationsSection invitations={invitations} context={invite} copy={copy} />
      </div>

      {dataIsMock ? (
        <div className="mt-6">
          <Notice tone="info">{copy.shell.testData}</Notice>
        </div>
      ) : null}
    </Shell>
  );
}
