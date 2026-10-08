import { StatusConfig } from "@/components/configuration/StatusConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Status (Configuration, migration 0005a): the work status list with its four flags, the default, retire and reactivate */
export default async function StatusPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configStatuses;
  const statuses = mayConfigure(me) ? await data().listConfigStatuses(me) : [];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-statuses" title={t.title} intro={t.intro}>
      <StatusConfig statuses={statuses} copy={copy} />
    </ConfigurationPage>
  );
}
