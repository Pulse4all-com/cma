import { forbidden } from "next/navigation";
import { MetricsCatalogView } from "@/components/configuration/MetricsCatalog";
import { data } from "@/lib/data";
import { isHttpsUrl } from "@/lib/health";
import { METRICS_PERMISSION } from "@/lib/metrics";
import { resolve } from "../../access";
import { ConfigurationPage } from "../gate";

/**
 * Configuration → Metrics: the metric catalog. Every figure the Workspace shows, as the code
 * computes it, from the build's copy of docs/metrics/catalog.json: the page costs no data read
 * beyond the tenant's settings (the current value next to each setting's default, and the data
 * map's address). The catalog itself ships inside the client component's own build chunk and a
 * card's body renders when it opens, so the served page stays small and fast however many figures
 * the catalog holds. Unlike the other configuration pages it answers a real 403 for everyone
 * without tenant.configure (and is absent from their rail): it is a reference page with no figure
 * of its own, and the brief of 23 October 2026 asks the route to refuse, not to explain.
 */
export default async function MetricsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  if (!me.permissions.includes(METRICS_PERMISSION)) forbidden();
  const settings = await data().listSettings(me);
  const datamapSetting = settings.find((s) => s.key === "health.link_datamap")?.value ?? "";
  const t = copy.configMetrics;
  return (
    <ConfigurationPage me={me} copy={copy} active="config-metrics" title={t.title} intro={t.intro} bare>
      <MetricsCatalogView t={t} settings={settings} datamap={isHttpsUrl(datamapSetting) ? datamapSetting : null} />
    </ConfigurationPage>
  );
}
