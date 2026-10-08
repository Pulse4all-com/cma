import { AppLinksConfig } from "@/components/configuration/AppLinksConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** AppLinks (Configuration, migration 0005a): the buttons on Welcome, per tenant */
export default async function AppLinksPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configAppLinks;
  const [links, permissions] = mayConfigure(me) ? await Promise.all([data().listConfigAppLinks(me), data().listPermissions(me)]) : [[], []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-app-links" title={t.title} intro={t.intro}>
      <AppLinksConfig links={links} permissions={permissions} copy={copy} />
    </ConfigurationPage>
  );
}
