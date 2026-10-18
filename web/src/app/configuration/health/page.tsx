import { Suspense } from "react";
import type { Principal } from "@/lib/auth/identity";
import type { Copy } from "@/lib/copy";
import { SystemHealth } from "@/components/configuration/SystemHealth";
import { Card } from "@/components/primitives";
import { config } from "@/lib/config";
import { data, requestDbTrace } from "@/lib/data";
import { isHttpsUrl } from "@/lib/health";
import { readManifest } from "../../api/v1/configuration/documents/[name]/route";
import { resolve } from "../../access";
import { ConfigurationPage, mayConfigure } from "../gate";

/**
 * System health (Configuration, addition 0008r; the IT audit of 17 October 2026): one read per card, all in
 * parallel, streamed behind the shell (the Suspense boundary renders the frame at once and the cards when the
 * reads answer). A refresh control instead of a poll. tenant.configure holders only; the database checks again.
 */
export default async function SystemHealthPage() {
  const r = await resolve();
  if (!r.ok) return r.page;
  const { me, copy } = r;
  const t = copy.configHealth;
  return (
    <ConfigurationPage me={me} copy={copy} active="config-health" title={t.title} intro={t.intro} bare>
      {mayConfigure(me) ? (
        <Suspense fallback={<Card><p className="text-body text-p4a-muted" aria-busy="true">{t.refreshing}</p></Card>}>
          <Panels me={me} copy={copy} />
        </Suspense>
      ) : null}
    </ConfigurationPage>
  );
}

async function Panels({ me, copy }: { me: Principal; copy: Copy }) {
  const d = data();
  const [probe, settings, sources, runs, outbox, manifest] = await Promise.all([
    d.probeDatabase(me), d.listSettings(me), d.listSources(me), d.getSystemHealthRuns(me), d.getOutboxStatus(me), readManifest(),
  ]);
  const link = (key: string) => { const v = settings.find((s) => s.key === key)?.value ?? ""; return isHttpsUrl(v) ? v : null; };
  // The cards stream after the Shell, so the Shell's cma-db meta does not count these reads: a second one, written
  // after them, carries the request's total (CMA_DB_TRACE=1 with mock sign-in only; verify/round-trips.mjs reads the last)
  const dbTrace = requestDbTrace();
  return (
    <>
      {dbTrace ? <meta name="cma-db" content={dbTrace} /> : null}
      <SystemHealth
        copy={copy} locale={me.locale} timeZone={me.timeZone} now={new Date().toISOString()}
        version={config.version} authMode={config.authMode} dataMode={config.dataMode}
        probe={probe} settings={settings} sources={sources} runs={runs} outbox={outbox} manifest={manifest}
        external={{ gemini: link("health.link_gemini_doc"), datamap: link("health.link_datamap") }}
      />
    </>
  );
}
