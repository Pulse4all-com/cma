import { MarketsConfig } from "@/components/configuration/MarketsConfig";
import { data } from "@/lib/data";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/** Markets (Configuration, addition 0008e): markets with their aliases, office hours and holidays */
export default async function MarketsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configMarkets;
  const [markets, skills] = mayConfigure(me) ? await Promise.all([data().getMarkets(me), data().listSkills(me)]) : [{ markets: [], hours: [], holidays: [] }, []];
  return (
    <ConfigurationPage me={me} copy={copy} active="config-markets" title={t.title} intro={t.intro} bare>
      <MarketsConfig data={markets} skills={skills} copy={copy} />
    </ConfigurationPage>
  );
}
