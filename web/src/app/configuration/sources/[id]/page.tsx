import Link from "next/link";
import { SourceConfig } from "@/components/configuration/SourceConfig";
import { Card } from "@/components/primitives";
import { data } from "@/lib/data";
import { CmaDbError } from "@/lib/db/client";
import { resolve } from "../../../access";
import { ConfigurationPage, mayConfigure } from "../../gate";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * One connection (Configuration → Sources, addition 0008e): its own fields, settings and the sections its
 * kind has. An id that is not a connection of the tenant shows a calm page, never another tenant's data.
 */
export default async function SourcePage({ params }: { params: Promise<{ id: string }> }) {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configSources;
  const { id } = await params;
  if (!mayConfigure(me)) {
    return <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro}>{null}</ConfigurationPage>;
  }
  let detail = null;
  if (UUID_RE.test(id)) {
    try {
      detail = await data().getSource(me, id.toLowerCase());
    } catch (e) {
      if (!(e instanceof CmaDbError && e.sqlState === "CMA02")) throw e;
    }
  }
  if (!detail) {
    return (
      <ConfigurationPage me={me} copy={copy} active="config-sources" title={t.title} intro={t.intro} bare>
        <Card title={t.notFoundTitle}>
          <p className="text-body">{t.notFoundBody}</p>
          <Link href="/configuration/sources" className="mt-4 inline-block text-small font-semibold text-p4a-deepblue hover:underline">← {t.back}</Link>
        </Card>
      </ConfigurationPage>
    );
  }
  const { markets } = await data().getMarkets(me);
  // the connected-call threshold (addition 0008j), shown in words on a telephony connection
  const threshold = (await data().listSettings(me)).find((x) => x.key === "telephony.connected_min_seconds")?.value;
  return (
    <ConfigurationPage me={me} copy={copy} active="config-sources" title={`${t.title}: ${detail.connection.name}`} intro={t.intro} bare>
      {/* keyed by the settings, so the editor starts again from the database's answer after a save */}
      <SourceConfig key={JSON.stringify(detail.connection.settings)} detail={detail} markets={markets} copy={copy} locale={me.locale} timeZone={me.timeZone}
        connectedMinSeconds={threshold === undefined ? null : Number(threshold)} />
    </ConfigurationPage>
  );
}
