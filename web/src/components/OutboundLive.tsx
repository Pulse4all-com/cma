/**
 * The Live board's Outbound today (addition 0009h; Martin, 10 November 2026): six tiles under Inbound today and above
 * Follow-up now, from cma.outbound_now: attempts, connected, the connected rate, the outbound conversations, the talk
 * time of the connected calls and its average. Today as Reports → Calls dates a call (its date in its line's zone, the
 * gap docs/definitions.md lists under Day; one zone for a tenant with one), so the figures are Reports → Calls' for today. Tenant-wide on every contact center's board, captioned as covering all lines, as the
 * inbound tiles (addition 0008zv). Counts and durations only. Nothing for a tenant without telephony: the inbound part
 * above already says "No telephony connected". One panel of six figures as Inbound today's (StatPanel, the Live board's
 * UX pass of 10 November 2026; docs/style/Pulse4all-Style.md 7.3), its Talk time in the column of Inbound today's.
 * Rendered by LiveBoardLive, so the board's 10-second poll refreshes it.
 */
import type { Copy, Locale } from "@/lib/copy";
import type { OutboundNow } from "@/lib/data";
import { OUTBOUND_TILES, outboundTileValue, type OutboundTileKey } from "@/lib/live";
import type { LiveHints } from "@/lib/live";
import { metricsHref } from "@/lib/metrics";
import { fillHint, fmtCount, fmtRate1, fmtTalk } from "@/lib/reports";
import { Stat, StatPanel } from "./StatPanel";

export function OutboundLive({ outbound, copy, locale, connectedMinSeconds, conversationMinSeconds, canOpenMetrics = false, scope }: {
  /** Null for a tenant without telephony: nothing is shown */
  outbound: OutboundNow | null; copy: Pick<Copy, "live"> & { hints: LiveHints }; locale: Locale;
  /** telephony.connected_min_seconds and calls.conversation_min_talk_seconds, for the hints */
  connectedMinSeconds: number | null; conversationMinSeconds: number | null;
  /** True for a holder of tenant.configure: each tile's hint links to its entry on Configuration -> Metrics */
  canOpenMetrics?: boolean;
  /** A caption under the title on what the figures cover (a contact center's Live board: all lines) */
  scope?: string;
}) {
  if (!outbound) return null;
  const t = copy.live;
  const h = copy.hints;
  const tiles: Record<OutboundTileKey, { label: string; hint: string; metric: string }> = {
    attempts: { label: t.outboundAttempts, hint: h.liveOutboundAttempts, metric: "live.outbound.attempts" },
    // Connected at any talk time, or from the tenant's threshold: the wording of Reports → Calls
    connected: { label: t.outboundConnected, hint: (connectedMinSeconds ?? 0) > 0 ? h.callsConnectedMin : h.callsConnected, metric: "live.outbound.connected" },
    connectedRate: { label: t.outboundConnectedRate, hint: h.callsConnectedRate, metric: "live.outbound.connected_rate" },
    conversations: { label: t.outboundConversations, hint: h.liveOutboundConversations, metric: "live.outbound.conversations" },
    talk: { label: t.outboundTalk, hint: h.liveOutboundTalk, metric: "live.outbound.talk" },
    talkAvg: { label: t.outboundAvgTalk, hint: h.liveOutboundAvgTalk, metric: "live.outbound.talk_avg" },
  };
  const info = (key: OutboundTileKey) => ({
    about: h.about.replace("{label}", tiles[key].label),
    text: fillHint(tiles[key].hint, { hours: h.officeHours, threshold: connectedMinSeconds, seconds: conversationMinSeconds }, locale),
    more: canOpenMetrics ? { href: metricsHref(tiles[key].metric), label: h.howComputed } : undefined,
  });
  const shown = (key: OutboundTileKey): string => {
    const v = outboundTileValue(outbound, key);
    if (v.kind === "count") return fmtCount(v.value, locale);
    if (v.kind === "rate") return fmtRate1(v.value, locale);
    return fmtTalk(v.value, locale);
  };

  return (
    <StatPanel id="outbound-today" title={t.outboundTitle} scope={scope} scopeTestId="outbound-scope" testId="outbound-live" figuresTestId="outbound-tiles">
      {OUTBOUND_TILES.map((key) => (
        <Stat key={key} testId={`outbound-${key}`} label={tiles[key].label} info={info(key)} value={shown(key)} locale={locale} />
      ))}
    </StatPanel>
  );
}
