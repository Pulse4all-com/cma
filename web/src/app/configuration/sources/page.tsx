import { FormCategories } from "@/components/configuration/FormCategories";
import { SourcesList } from "@/components/configuration/SourcesList";
import { Card } from "@/components/primitives";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/**
 * Sources (Configuration, addition 0008e): the tenant's connections, one row each; a row opens its page. Since
 * addition 0008p the form categories follow: the catalog a form's category is chosen from on its connection's page
 */
export default async function SourcesPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configSources;
  const may = mayConfigure(me);
  const [sources, categories] = may ? await Promise.all([data().listSources(me), data().getFormCategories(me)]) : [[], []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro} bare>
      <Card>
        <SourcesList sources={sources} copy={copy} locale={me.locale} timeZone={me.timeZone} />
      </Card>
      <FormCategories categories={categories} copy={copy} />
    </ConfigurationPage>
  );
}
