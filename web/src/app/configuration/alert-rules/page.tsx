import { AlertRulesConfig } from "@/components/configuration/AlertRulesConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Alert rules (Configuration, brief B14, addition 0008e): which new or assigned records alert whom */
export default async function AlertRulesPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configAlertRules;
  const [rules, permissions] = mayConfigure(me)
    ? await Promise.all([data().getAlertRules(me), data().listPermissions(me)])
    : [{ rules: [], pipelines: [], defaultMaxAgeMinutes: 60, negativeMaxRating: 2 }, []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-alert-rules" title={t.title} intro={t.intro}>
      <AlertRulesConfig data={rules} permissions={permissions} copy={copy} locale={me.locale} timeZone={me.timeZone} />
    </ConfigurationPage>
  );
}
