import { ExportsConfig } from "@/components/configuration/ExportsConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Exports (Configuration, migration 0005a): the five CSV settings with a preview, and the minute settings */
export default async function ExportsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configExports;
  const settings = mayConfigure(me) ? await data().listSettings(me) : [];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-exports" title={t.title} intro={t.intro}>
      <ExportsConfig settings={settings} copy={copy} />
    </ConfigurationPage>
  );
}
