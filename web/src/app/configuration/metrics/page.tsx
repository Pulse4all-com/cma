import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { MetricsCatalogView } from "@/components/configuration/MetricsCatalog";
import { data } from "@/lib/data";
import { isHttpsUrl } from "@/lib/health";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/**
 * Configuration → Metrics: the metric catalog. Every figure the Workspace shows, as the code
 * computes it, from the build's copy of docs/metrics/catalog.json: the page costs no data read
 * beyond the tenant's settings (the current value next to each setting's default, and the data
 * map's address), and nothing is read for a person without tenant.configure, who gets the same
 * calm no-permission card as every other configuration page (ConfigurationPage, the gate; the rail
 * hides the item through nav.ts, as everywhere). The catalog itself ships inside the client
 * component's own build chunk and a card's body renders when it opens, so the served page stays
 * small and fast however many figures the catalog holds.
 */
export default async function MetricsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configMetrics;
  return (
    <ConfigurationPage me={me} copy={copy} active="config-metrics" title={t.title} intro={t.intro} bare>
      {mayConfigure(me) ? <Catalog me={me} copy={copy} /> : null}
    </ConfigurationPage>
  );
}

async function Catalog({ me, copy }: { me: Principal; copy: Copy }) {
  const settings = await data().listSettings(me);
  const datamapSetting = settings.find((s) => s.key === "health.link_datamap")?.value ?? "";
  return (
    <MetricsCatalogView t={copy.configMetrics} settings={settings} datamap={isHttpsUrl(datamapSetting) ? datamapSetting : null} />
  );
}
