import { SourcesList } from "@/components/configuration/SourcesList";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Sources (Configuration, addition 0008e): the tenant's connections, one row each; a row opens its page */
export default async function SourcesPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configSources;
  const sources = mayConfigure(me) ? await data().listSources(me) : [];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro}>
      <SourcesList sources={sources} copy={copy} locale={me.locale} timeZone={me.timeZone} />
    </ConfigurationPage>
  );
}
