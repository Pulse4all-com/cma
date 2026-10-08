import { AbsenceConfig } from "@/components/configuration/AbsenceConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Absence (Configuration, migration 0005a): the absence types and the coverage targets per team */
export default async function AbsencePage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configAbsences;
  const [absences, teams, skills, targets] = mayConfigure(me)
    ? await Promise.all([data().listAbsenceTypes(me), data().listTeams(me), data().listSkills(me), data().listCoverageTargets(me)])
    : [[], [], [], []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-absences" title={t.title} intro={t.intro}>
      <AbsenceConfig absences={absences} teams={teams} skills={skills} targets={targets} copy={copy} />
    </ConfigurationPage>
  );
}
