/**
 * Building blocks of the intake reports (B11): the no-permission card, the not-connected state, the
 * grouping switches (Speed to lead, and Inbound since 0008i) and the external record link (the Dashboard's Intake row
 * has its own file, components/IntakeRow, since 12 November 2026). The
 * figures arrive from the data layer and lib/reports arranges them. No customer data: ids, counts,
 * codes and links only.
 */
import Link from "next/link";
import type { Copy } from "@/lib/copy";
import type { InboundGroup, SpeedToLeadGroup } from "@/lib/data";
import { INBOUND_GROUPS, nextGroup, nextInboundGroup, SPEED_TO_LEAD_GROUPS } from "@/lib/reports";
import { Card, Keycap } from "./primitives";

export { RecordLink } from "./RecordLink";

export function NoReportPermission({ title, body }: { title: string; body: string }) {
  return (
    <Card>
      <h2 className="text-panel font-semibold text-p4a-heading">{title}</h2>
      <p className="mt-2 text-body">{body}</p>
    </Card>
  );
}

/** A source that is not connected: said in words, never shown as 0 */
export function NotConnected({ label, hint }: { label: string; hint: string }) {
  return (
    <span className="text-small text-p4a-muted" title={hint} data-testid="not-connected">
      {label}
    </span>
  );
}

/** Day, market, agent or pipeline as links; G moves to the next one */
export function GroupSwitch({
  group, query, copy,
}: { group: SpeedToLeadGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.speedToLead;
  const labels: Record<SpeedToLeadGroup, string> = { day: t.day, market: t.market, agent: t.agent, pipeline: t.pipeline };
  const next = nextGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {SPEED_TO_LEAD_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/speed-to-lead", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

/** Day, market, line or hour as links on the Inbound report (addition 0008i); G moves to the next one */
export function InboundGroupSwitch({
  group, query, copy,
}: { group: InboundGroup; query: Record<string, string>; copy: Copy }) {
  const t = copy.inbound;
  const labels: Record<InboundGroup, string> = { day: t.day, market: t.market, line: t.line, hour: t.hour };
  const next = nextInboundGroup(group);
  return (
    <div className="flex flex-col gap-2 text-small font-semibold">
      <span className="flex items-center gap-2">
        {t.groupBy} <Keycap>G</Keycap>
      </span>
      <nav aria-label={t.groupBy} className="flex gap-2">
        {INBOUND_GROUPS.map((g) => (
          <Link
            key={g}
            href={{ pathname: "/reports/inbound", query: { ...query, group: g } }}
            aria-current={g === group ? "page" : undefined}
            data-shortcut={g === next ? "g" : undefined}
            className={[
              "inline-flex h-10 items-center rounded-button border px-4 text-body font-semibold",
              g === group ? "border-p4a-deepblue bg-p4a-deepblue text-white" : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[g]}
          </Link>
        ))}
      </nav>
    </div>
  );
}

