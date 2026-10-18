/**
 * System health (Configuration → System health, addition 0008r; the IT audit of 17 October 2026): six cards.
 * This application (version, modes, one timed read), the ingest heartbeat (the sweep's link_calls run per
 * minute against the tenant's two thresholds), the sources (a state per connection derived in lib/health from
 * what the jobs and events left behind), the jobs (one row per job and connection from cma.system_health_runs),
 * the outbox (cma.outbox_status) and the documents of this build (the manifest the build wrote). Colours by
 * meaning with a label on every state (Pulse4all-Style.md 7.5); counts, ages and codes only, never a secret
 * name's value, never a connection key, never personal data. A server component: the reads run in parallel
 * in the page and arrive as props; the page streams the shell first (loading.tsx).
 */
import type { Copy, Locale } from "@/lib/copy";
import type { DatabaseProbe, OutboxStatusRow, SourceConnection, SystemHealthRun, TenantSetting } from "@/lib/data";
import {
  ageSeconds, connectionState, heartbeatRun, heartbeatState, heartbeatThresholds, jobState, probeState, runDurationMs, runsByJob,
  type ConnectionState, type DocumentsManifest, type HeartbeatState, type JobState,
} from "@/lib/health";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { HeaderHint } from "../HeaderHint";
import { Badge, Card } from "../primitives";
import { RefreshButton } from "./RefreshButton";
import { td, th, tr } from "./tableClasses";

type BadgeTone = Parameters<typeof Badge>[0]["tone"];

export interface SystemHealthProps {
  copy: Copy;
  locale: Locale;
  timeZone: string;
  now: string;
  version: string;
  authMode: "iap" | "mock";
  dataMode: "api" | "mock";
  probe: DatabaseProbe;
  settings: TenantSetting[];
  sources: SourceConnection[];
  runs: SystemHealthRun[];
  outbox: OutboxStatusRow[];
  manifest: DocumentsManifest | null;
  /** External links from the tenant's settings (health.link_gemini_doc, health.link_datamap), null when not set */
  external: { gemini: string | null; datamap: string | null };
}

/** Thu 12 Oct 14:05 in the viewer's zone, as the Sources list writes it */
function when(instant: string, locale: Locale, timeZone: string): string {
  return `${fmtDate(dateKeyInZone(new Date(instant), timeZone), locale, "compact")} ${fmtTime(instant, timeZone, locale)}`;
}

/** 42 s, 7 min, 3 h, 2 d: one unit, the largest that fits */
function fmtAge(seconds: number, t: Copy["configHealth"]): string {
  if (seconds < 60) return t.seconds.replace("{n}", String(seconds));
  if (seconds < 3600) return t.minutes.replace("{n}", String(Math.floor(seconds / 60)));
  if (seconds < 86400) return t.hours.replace("{n}", String(Math.floor(seconds / 3600)));
  return t.days.replace("{n}", String(Math.floor(seconds / 86400)));
}

function fmtBytes(bytes: number, locale: Locale): string {
  const kb = Math.max(1, Math.round(bytes / 1024));
  return `${new Intl.NumberFormat(locale === "nl" ? "nl-NL" : "en-GB").format(kb)} kB`;
}

const heartbeatTone: Record<HeartbeatState, BadgeTone> = { fresh: "success", late: "warning", silent: "error", none: "neutral" };
const connectionTone: Record<ConnectionState, BadgeTone> = { ok: "success", attention: "warning", failing: "error", off: "neutral" };
const jobTone: Record<JobState, BadgeTone> = { ok: "success", failed: "error", running: "info", stuck: "error", never: "neutral" };

export function SystemHealth(p: SystemHealthProps) {
  const t = p.copy.configHealth;
  const nowMs = Date.parse(p.now);
  const hint = (label: string, text: string) => <HeaderHint label={p.copy.hints.about.replace("{label}", label)} text={text} />;
  const thresholds = heartbeatThresholds(p.settings);
  const beat = heartbeatRun(p.runs);
  const beatAge = ageSeconds(beat?.lastStartedAt ?? null, nowMs);
  const beatState = heartbeatState(beatAge, thresholds);
  const probe = probeState(p.probe.roundTripMs);
  const jobLabel = (job: string) => (t as Record<string, string>)[`job_${job}`] ?? job;
  const docLabel = (name: string) => (t as Record<string, string>)[`doc_${name.replace(/\.[a-z]+$/, "")}`] ?? name;
  const sourceName = (id: string | null) => (id === null ? t.tenantWide : p.sources.find((s) => s.id === id)?.name ?? id.slice(0, 8));
  const stateLabel: Record<ConnectionState, string> = { ok: t.stateOk, attention: t.stateAttention, failing: t.stateFailing, off: t.stateOff };
  const jobLabelOf: Record<JobState, string> = { ok: t.jobOk, failed: t.jobFailed, running: t.jobRunning, stuck: t.jobStuck, never: t.jobNever };

  return (
    <div className="flex flex-col gap-6" data-testid="system-health">
      <div className="flex items-center justify-between">
        <p className="text-small text-p4a-muted">{t.asOf.replace("{time}", when(p.now, p.locale, p.timeZone))}</p>
        <RefreshButton label={t.refresh} pendingLabel={t.refreshing} />
      </div>

      <div className="grid grid-cols-2 gap-6">
        {/* 1. This application */}
        <Card title={t.appTitle}>
          <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2 text-body" data-testid="health-app">
            <dt className="text-p4a-muted">{t.version}</dt><dd className="tabular font-semibold">{p.version}</dd>
            <dt className="text-p4a-muted">{t.authMode}</dt><dd>{p.authMode === "iap" ? t.authIap : t.authMock}</dd>
            <dt className="text-p4a-muted">{t.dataMode}</dt><dd>{p.dataMode === "api" ? t.dataApi : t.dataMock}</dd>
            <dt className="text-p4a-muted">{t.probe}{hint(t.probe, t.probeHint)}</dt>
            <dd className="flex items-center gap-3">
              <Badge tone={probe === "fast" ? "success" : probe === "slow" ? "warning" : "error"}>
                {probe === "fast" ? t.probeFast : probe === "slow" ? t.probeSlow : t.probeDown}
              </Badge>
              {p.probe.roundTripMs !== null ? <span className="tabular text-small text-p4a-muted">{p.probe.roundTripMs} ms</span> : null}
            </dd>
          </dl>
        </Card>

        {/* 2. Ingest heartbeat */}
        <Card title={t.heartbeatTitle}>
          <div className="flex items-center gap-3" data-testid="health-heartbeat" data-state={beatState}>
            <Badge tone={heartbeatTone[beatState]}>
              {beatState === "fresh" ? t.heartbeatFresh : beatState === "late" ? t.heartbeatLate : beatState === "silent" ? t.heartbeatSilent : t.heartbeatNone}
            </Badge>
            {beatAge !== null ? <span className="text-body">{t.heartbeatAge.replace("{age}", fmtAge(beatAge, t))}</span> : null}
            {hint(t.heartbeatTitle, t.heartbeatHint)}
          </div>
          <p className="mt-3 text-caption text-p4a-grey">
            {t.heartbeatThresholds.replace("{fresh}", fmtAge(thresholds.freshSeconds, t)).replace("{late}", fmtAge(thresholds.lateSeconds, t))}
          </p>
        </Card>
      </div>

      {/* 3. Sources */}
      <Card title={t.sourcesTitle}>
        {p.sources.length === 0 ? <p className="text-body text-p4a-muted">{t.sourcesEmpty}</p> : (
          <table className="w-full border-collapse text-body leading-table" data-testid="health-sources">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.source}</th>
                <th className={th}>{t.state}{hint(t.state, t.stateHint)}</th>
                <th className={th}>{t.lastEvent}</th>
                <th className={`${th} text-right`}>{t.events24h}</th>
                <th className={th}>{t.lastReadBack}</th>
                <th className={th}>{t.lastFailure}</th>
              </tr>
            </thead>
            <tbody>
              {p.sources.map((s) => {
                const mine = p.runs.filter((r) => r.connectionId === s.id);
                const state = connectionState({ id: s.id, isActive: s.isActive, events24h: s.events24h, eventsWaiting: s.eventsWaiting, eventsParked: s.eventsParked, lastEventAt: s.lastEventAt }, p.runs, nowMs);
                const lastOk = mine.map((r) => r.lastSucceededAt).filter((x): x is string => x !== null).sort().at(-1) ?? null;
                const lastBad = mine.filter((r) => r.lastFailedAt !== null).sort((a, b) => (a.lastFailedAt! < b.lastFailedAt! ? 1 : -1))[0] ?? null;
                return (
                  <tr key={s.id} className={tr} data-state={state}>
                    <td className={td}><span className="font-semibold">{s.name}</span><span className="block text-caption text-p4a-muted">{s.adapter}</span></td>
                    <td className={td}><Badge tone={connectionTone[state]}>{stateLabel[state]}</Badge></td>
                    <td className={`${td} text-small tabular`}>{s.lastEventAt ? when(s.lastEventAt, p.locale, p.timeZone) : "–"}</td>
                    <td className={`${td} text-right tabular-nums`}>
                      {s.events24h}
                      <span className="block text-caption text-p4a-muted">{s.eventsWaiting} {t.waiting.toLowerCase()} · {s.eventsParked > 0 ? <Badge tone="warning">{s.eventsParked}</Badge> : 0} {t.parked.toLowerCase()}</span>
                    </td>
                    <td className={`${td} text-small tabular`}>{lastOk ? when(lastOk, p.locale, p.timeZone) : "–"}</td>
                    <td className={`${td} text-small`}>
                      {lastBad ? <><span className="tabular">{when(lastBad.lastFailedAt!, p.locale, p.timeZone)}</span><span className="block text-caption text-p4a-muted">{jobLabel(lastBad.job)} · {lastBad.lastFailedError}</span></> : "–"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </Card>

      {/* 4. Jobs */}
      <Card title={t.jobsTitle}>
        {p.runs.length === 0 ? <p className="text-body text-p4a-muted">{t.jobsEmpty}</p> : (
          <table className="w-full border-collapse text-body leading-table" data-testid="health-jobs">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.job}{hint(t.job, t.jobsHint)}</th>
                <th className={th}>{t.source}</th>
                <th className={th}>{t.lastRun}</th>
                <th className={`${th} text-right`}>{t.duration}</th>
                <th className={th}>{t.outcome}</th>
                <th className={th}>{t.counts}</th>
                <th className={`${th} text-right`}>{t.runs24h}</th>
              </tr>
            </thead>
            <tbody>
              {runsByJob(p.runs).flatMap((g) => g.runs.map((r) => {
                const state = jobState(r, nowMs);
                const took = runDurationMs(r);
                const counts = Object.entries(r.lastCounts).filter(([, v]) => v > 0).map(([k, v]) => `${k} ${v}`).join(", ");
                return (
                  <tr key={`${r.job}:${r.connectionId ?? "all"}`} className={tr} data-job={r.job} data-state={state}>
                    <td className={`${td} font-semibold`}>{jobLabel(r.job)}</td>
                    <td className={`${td} text-small`}>{sourceName(r.connectionId)}</td>
                    <td className={`${td} text-small tabular`}>{when(r.lastStartedAt, p.locale, p.timeZone)}</td>
                    <td className={`${td} text-right text-small tabular-nums`}>{took === null ? "–" : took < 1000 ? `${took} ms` : fmtAge(Math.round(took / 1000), t)}</td>
                    <td className={td}>
                      <Badge tone={jobTone[state]}>{jobLabelOf[state]}</Badge>
                      {r.lastError ? <span className="ml-2 text-caption text-p4a-muted">{r.lastError}</span> : null}
                    </td>
                    <td className={`${td} text-small text-p4a-muted`}>{counts || "–"}</td>
                    <td className={`${td} text-right tabular-nums`}>
                      {r.runs24h}
                      {r.failed24h > 0 ? <span className="block text-caption"><Badge tone="warning">{t.failed24h.replace("{n}", String(r.failed24h))}</Badge></span> : null}
                    </td>
                  </tr>
                );
              }))}
            </tbody>
          </table>
        )}
      </Card>

      <div className="grid grid-cols-2 gap-6">
        {/* 5. Outbox */}
        <Card title={t.outboxTitle}>
          <p className="mb-3 text-caption text-p4a-grey">{t.outboxHint}</p>
          {p.outbox.length === 0 ? <p className="text-body text-p4a-muted">{t.outboxEmpty}</p> : (
            <table className="w-full border-collapse text-body leading-table" data-testid="health-outbox">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.source}</th>
                  <th className={th}>{t.state}</th>
                  <th className={`${th} text-right`}>{t.actions}</th>
                  <th className={th}>{t.oldest}</th>
                  <th className={th}>{t.nextAttempt}</th>
                </tr>
              </thead>
              <tbody>
                {p.outbox.map((o) => (
                  <tr key={`${o.connectionId}:${o.status}`} className={tr}>
                    <td className={`${td} font-semibold`}>{o.connectionName}</td>
                    <td className={td}><Badge tone={o.status === "sent" ? "success" : o.status === "needs_review" || o.status === "failed" ? "error" : o.status === "pending" || o.status === "in_flight" ? "info" : "neutral"}>{o.status}</Badge></td>
                    <td className={`${td} text-right tabular-nums`}>{o.actions}</td>
                    <td className={`${td} text-small tabular`}>{o.oldestAt ? when(o.oldestAt, p.locale, p.timeZone) : "–"}</td>
                    <td className={`${td} text-small tabular`}>{o.nextAttemptAt ? when(o.nextAttemptAt, p.locale, p.timeZone) : "–"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>

        {/* 6. Documents */}
        <Card title={t.documentsTitle}>
          <p className="mb-3 text-caption text-p4a-grey">{t.documentsIntro}</p>
          {!p.manifest || p.manifest.documents.length === 0 ? <p className="text-body text-p4a-muted">{t.documentsEmpty}</p> : (
            <table className="w-full border-collapse text-body leading-table" data-testid="health-documents">
              <thead className="bg-p4a-bgblue text-small text-p4a-heading">
                <tr>
                  <th className={th}>{t.document}</th>
                  <th className={`${th} text-right`}>{t.size}</th>
                  <th className={th}></th>
                </tr>
              </thead>
              <tbody>
                {p.manifest.documents.map((d) => (
                  <tr key={d.name} className={tr}>
                    <td className={td}><span className="font-semibold">{docLabel(d.name)}</span><span className="block text-caption text-p4a-muted tabular">{d.name}</span></td>
                    <td className={`${td} text-right text-small tabular-nums`}>{fmtBytes(d.bytes, p.locale)}</td>
                    <td className={`${td} text-right`}>
                      <a href={`/api/v1/configuration/documents/${encodeURIComponent(d.name)}`} download={d.name} className="inline-flex h-8 items-center rounded-button border border-p4a-deepblue px-3 text-small font-semibold text-p4a-deepblue hover:bg-p4a-bgblue">
                        {t.download}
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <h3 className="mt-6 text-small font-semibold text-p4a-heading">{t.externalTitle}{hint(t.externalTitle, t.externalHint)}</h3>
          <ul className="mt-2 flex flex-col gap-1 text-body" data-testid="health-external">
            <li>{p.external.gemini ? <a href={p.external.gemini} target="_blank" rel="noreferrer noopener" className="font-semibold text-p4a-deepblue hover:underline">{t.externalGemini}</a> : <span className="text-p4a-muted">{t.externalGemini} · {t.externalNotSet}</span>}</li>
            <li>{p.external.datamap ? <a href={p.external.datamap} target="_blank" rel="noreferrer noopener" className="font-semibold text-p4a-deepblue hover:underline">{t.externalDatamap}</a> : <span className="text-p4a-muted">{t.externalDatamap} · {t.externalNotSet}</span>}</li>
          </ul>
        </Card>
      </div>
    </div>
  );
}
