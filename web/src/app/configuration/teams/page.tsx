import { TeamsConfig } from "@/components/configuration/TeamsConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Teams (Configuration, migration 0005a): the current teams and the skill catalog with its level scales */
export default async function TeamsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configTeams;
  const [teams, skills] = mayConfigure(me) ? await Promise.all([data().listTeams(me), data().listSkills(me)]) : [[], []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-teams" title={t.title} intro={t.intro}>
      <TeamsConfig teams={teams} skills={skills} copy={copy} />
    </ConfigurationPage>
  );
}
