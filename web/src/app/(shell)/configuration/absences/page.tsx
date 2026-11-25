import { AbsenceConfig } from "@/components/configuration/AbsenceConfig";
import { AssignmentTypesConfig } from "@/components/configuration/AssignmentTypesConfig";
import { data } from "@/lib/data";
import { resolve } from "@/app/access";
import { ConfigurationPage, mayConfigure } from "../gate";
import { pickCopy } from "@/lib/copy";

/**
 * Roster (Configuration, migration 0005a; named Roster since addition 0009zw, the address kept): the assignment types and
 * the planner's settings (brief A, D2, D6), the absence types with Carries over (D10) and the coverage targets per team
 */
export default async function AbsencePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configAbsences;
  // The roster's catalogs and settings in one transaction (addition 0009zw): the page gains one transaction, not three
  const [absences, teams, skills, targets, roster] = mayConfigure(me)
    ? await Promise.all([
      data().listAbsenceTypes(me), data().listTeams(me), data().listSkills(me), data().listCoverageTargets(me), data().getRosterConfiguration(me),
    ])
    : [[], [], [], [], { types: [], statuses: [], settings: [] }];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-absences" title={t.title} intro={t.intro}>
      <div className="flex flex-col gap-12">
        <AssignmentTypesConfig types={roster.types} statuses={roster.statuses} settings={roster.settings} copy={pickCopy(copy, "configAssignments", "configuration")} />
        <AbsenceConfig absences={absences} teams={teams} skills={skills} targets={targets} copy={pickCopy(copy, "configAbsences", "configTeams", "configuration", "configAssignments")} />
      </div>
    </ConfigurationPage>
  );
}
