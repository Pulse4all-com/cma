import { forbidden } from "next/navigation";
import { MetricsCatalogView } from "@/components/configuration/MetricsCatalog";
import { data } from "@/lib/data";
import { isHttpsUrl } from "@/lib/health";
import { METRICS_PERMISSION, type MetricCatalog } from "@/lib/metrics";
import rawCatalog from "@/lib/metrics-catalog.json";
import { resolve } from "../../access";
import { ConfigurationPage } from "../gate";

/**
 * Configuration → Metrics: the metric catalog. Every figure the Workspace shows, as the code
 * computes it, rendered from the build's copy of docs/metrics/catalog.json: the page costs no data
 * read beyond the tenant's settings (the current value next to each setting's default, and the data
 * map's address). Unlike the other configuration pages it answers a real 403 for everyone without
 * tenant.configure (and is absent from their rail): it is a reference page with no figure of its
 * own, and the brief of 23 October 2026 asks the route to refuse, not to explain.
 */
export default async function MetricsPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  if (!me.permissions.includes(METRICS_PERMISSION)) forbidden();
  const catalog = rawCatalog as unknown as MetricCatalog;
  const settings = await data().listSettings(me);
  const current = new Map(settings.map((s) => [s.key, { value: s.value, isDefault: s.isDefault }]));
  const datamapSetting = settings.find((s) => s.key === "health.link_datamap")?.value ?? "";
  const t = copy.configMetrics;
  return (
    <ConfigurationPage me={me} copy={copy} active="config-metrics" title={t.title} intro={t.intro} bare>
      <MetricsCatalogView
        entries={catalog.entries}
        copy={copy}
        current={current}
        datamap={isHttpsUrl(datamapSetting) ? datamapSetting : null}
      />
    </ConfigurationPage>
  );
}
