/**
 * The Live board's Outbound today (addition 0009h; Martin, 10 November 2026): six tiles under Inbound today and above
 * Follow-up now, from cma.outbound_now: attempts, connected, the connected rate, the outbound conversations, the talk
 * time of the connected calls and its average. Today is Day: each call's date in its line's zone, so the figures are
 * Reports → Calls' for today. Tenant-wide on every contact center's board, captioned as covering all lines, as the
 * inbound tiles (addition 0008zv). Counts and durations only. Nothing for a tenant without telephony: the inbound part
 * above already says "No telephony connected". Tiles as InboundLive's (docs/style/Pulse4all-Style.md 7.3), three to a
 * row at 1280 px and six from 1536 px, as the follow-up strip. Rendered by LiveBoardLive, so the board's 10-second poll
 * refreshes it.
 */
import type { Copy, Locale } from "@/lib/copy";
import type { OutboundNow } from "@/lib/data";
import { OUTBOUND_TILES, outboundTileValue, type OutboundTileKey } from "@/lib/live";
import { metricsHref } from "@/lib/metrics";
import { fillHint, fmtCount, fmtRate1, fmtTalk } from "@/lib/reports";
import { Tile } from "./InboundLive";

export function OutboundLive({ outbound, copy, locale, connectedMinSeconds, conversationMinSeconds, canOpenMetrics = false, scope }: {
  /** Null for a tenant without telephony: nothing is shown */
  outbound: OutboundNow | null; copy: Pick<Copy, "live" | "hints">; locale: Locale;
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
    <section aria-labelledby="outbound-today" className="flex flex-col gap-4" data-testid="outbound-live">
      <div>
        <h2 id="outbound-today" className="text-panel font-semibold text-p4a-heading">{t.outboundTitle}</h2>
        {scope ? <p className="mt-1 text-small text-p4a-muted" data-testid="outbound-scope">{scope}</p> : null}
      </div>
      <div className="grid grid-cols-3 gap-4 2xl:grid-cols-6" data-testid="outbound-tiles">
        {OUTBOUND_TILES.map((key) => (
          <Tile key={key} testId={`outbound-${key}`} label={tiles[key].label} info={info(key)} value={shown(key)} />
        ))}
      </div>
    </section>
  );
}
