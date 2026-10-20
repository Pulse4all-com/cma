/**
 * Sources (addition 0008e): every connection of the tenant, one row each, with its vendor as stored,
 * its kind, account, status and the events of the last day; a row opens the connection's page. No
 * connection is created here: a connection names its secrets, so it is added with the runbook.
 */
import Link from "next/link";
import type { Copy } from "@/lib/copy";
import type { SourceConnection } from "@/lib/data";
import type { Locale } from "@/lib/copy";
import { dateKeyInZone, fmtDate, fmtTime } from "@/lib/time";
import { HeaderHint } from "../HeaderHint";
import { HintLabel } from "../HintLabel";
import { Badge } from "../primitives";
import { td, th, tr } from "./tableClasses";

export function kindLabel(kind: SourceConnection["kind"], t: Copy["configSources"]): string {
  return kind ? (t as Record<string, string>)[`kind_${kind}`] ?? kind : t.kindNotSet;
}

/** Thu 12 Oct 14:05 in the viewer's zone */
export function fmtWhen(instant: string, locale: Locale, timeZone: string): string {
  return `${fmtDate(dateKeyInZone(new Date(instant), timeZone), locale, "compact")} ${fmtTime(instant, timeZone, locale)}`;
}

export function SourcesList({ sources, copy, locale, timeZone }: { sources: SourceConnection[]; copy: Copy; locale: Locale; timeZone: string }) {
  const t = copy.configSources;
  const hint = (label: string, text: string) => <HeaderHint label={copy.hints.about.replace("{label}", label)} text={text} />;
  if (sources.length === 0) return <p className="text-body text-p4a-muted">{t.empty}</p>;
  return (
    <table className="w-full border-collapse text-body leading-table" data-testid="sources">
      <thead className="bg-p4a-bgblue text-small text-p4a-heading">
        <tr>
          <th className={th}>{t.connection}</th>
          <th className={th}><HintLabel label={t.kind}>{hint(t.kind, t.kindHint)}</HintLabel></th>
          <th className={th}>{t.account}</th>
          <th className={th}>{t.status}</th>
          <th className={`${th} text-right`}>{t.events}</th>
          <th className={th}>{t.lastEvent}</th>
          <th className={th}></th>
        </tr>
      </thead>
      <tbody>
        {sources.map((s) => (
          <tr key={s.id} className={`${tr} ${s.isActive ? "" : "text-p4a-muted"}`}>
            <td className={td}><span className="font-semibold">{s.name}</span><span className="block text-caption text-p4a-muted">{t.vendor}: {s.adapter}</span></td>
            <td className={`${td} text-small`}>{kindLabel(s.kind, t)}</td>
            <td className={`${td} text-small tabular-nums`}>{s.accountId}</td>
            <td className={td}>{s.isActive ? <Badge tone="success">{t.active}</Badge> : <Badge tone="neutral">{t.inactive}</Badge>}</td>
            <td className={`${td} text-right tabular-nums`}>
              {s.events24h}
              <span className="block text-caption text-p4a-muted">{s.eventsWaiting} {t.waiting.toLowerCase()} · {s.eventsParked > 0 ? <Badge tone="warning">{s.eventsParked}</Badge> : 0} {t.parked.toLowerCase()}</span>
            </td>
            <td className={`${td} text-small`}>{s.lastEventAt ? fmtWhen(s.lastEventAt, locale, timeZone) : t.never}</td>
            <td className={`${td} text-right`}>
              <Link href={`/configuration/sources/${s.id}`} className="inline-flex h-8 items-center rounded-button border border-p4a-deepblue px-3 text-small font-semibold text-p4a-deepblue hover:bg-p4a-bgblue">
                {t.open}
              </Link>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
