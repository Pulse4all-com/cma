"use client";

/**
 * The sent list of Send a message (migration 0008): the messages and alerts of the last 30 days, newest first, with
 * recipients, read and confirmed counts and the median time to read (cma.message_stats). Since addition 0008z a person
 * holding messages.withdraw deletes a message for everyone from here, after a confirmation that opens on Cancel; a
 * withdrawn message stays in the list marked Deleted, its counts frozen, as the audit keeps it.
 */
import { useState } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { MessageStat } from "@/lib/data";
import { fmtSeconds } from "@/lib/messages";
import { fmtDateTimeShort } from "@/lib/time";
import { MessageWithdraw } from "./MessageWithdraw";
import { Badge } from "./primitives";

export function SentMessages({ stats, copy, timeZone, locale, canWithdraw }: {
  stats: MessageStat[]; copy: Copy["messages"]; timeZone: string; locale: Locale;
  /** The viewer holds messages.withdraw */
  canWithdraw: boolean;
}) {
  const [list, setList] = useState<MessageStat[]>(() => [...stats].reverse());
  if (list.length === 0) return <p className="text-body text-p4a-muted">{copy.sentEmpty}</p>;
  return (
    <table className="w-full text-small" data-testid="sent-table">
      <thead className="text-left text-p4a-muted">
        <tr>
          <th className="h-9 pr-3 font-semibold">{copy.colWhen}</th>
          <th className="h-9 pr-3 font-semibold">{copy.colTitle}</th>
          <th className="h-9 pr-3 text-right font-semibold">{copy.colRecipients}</th>
          <th className="h-9 pr-3 text-right font-semibold">{copy.colRead}</th>
          <th className="h-9 pr-3 text-right font-semibold">{copy.colAcknowledged}</th>
          <th className="h-9 text-right font-semibold">{copy.colMedian}</th>
          {canWithdraw ? <th className="h-9 pl-3"><span className="sr-only">{copy.delete}</span></th> : null}
        </tr>
      </thead>
      <tbody>
        {list.map((s) => (
          <tr key={s.id} className="border-t border-p4a-border" data-testid="sent-row" data-withdrawn={s.withdrawnAt ? "true" : "false"}>
            <td className="py-2 pr-3 tabular text-p4a-muted">{fmtDateTimeShort(s.createdAt, timeZone, locale)}</td>
            <td className="py-2 pr-3">
              <span className="flex items-center gap-2">
                {s.withdrawnAt ? <Badge tone="neutral">{copy.deleted}</Badge> : null}
                {s.byRule ? <Badge tone="info">{copy.byRule}</Badge> : null}
                {s.urgency === "urgent" ? <Badge tone="warning">{copy.urgent}</Badge> : null}
                <span className={s.withdrawnAt ? "text-p4a-muted line-through" : undefined}>{s.title}</span>
              </span>
            </td>
            <td className="py-2 pr-3 text-right tabular">{s.recipients}</td>
            <td className="py-2 pr-3 text-right tabular">{s.read}</td>
            <td className="py-2 pr-3 text-right tabular">{s.urgency === "urgent" ? s.acknowledged : "–"}</td>
            <td className="py-2 text-right tabular">{fmtSeconds(s.medianSecondsToRead)}</td>
            {canWithdraw ? (
              <td className="py-2 pl-3 text-right">
                {s.withdrawnAt ? null : (
                  <MessageWithdraw id={s.id} title={s.title} copy={copy}
                    onWithdrawn={(at) => setList((l) => l.map((x) => (x.id === s.id ? { ...x, withdrawnAt: at } : x)))} />
                )}
              </td>
            ) : null}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
