"use client";

/**
 * The inbox (migration 0008): the person's own messages, newest first, unread ones marked. Opening a
 * record link or pressing Acknowledge reads the message; M marks everything read. The desktop
 * notification permission is asked here, from a button, never on load. Refreshes itself when the
 * message centre reports an arrival. A person holding messages.withdraw deletes a message for everyone from
 * here (addition 0008z), after a confirmation that opens on Cancel. References only: a title, a body and a
 * link, never customer data.
 */
import { useEffect, useState, useSyncExternalStore, useTransition } from "react";
import type { Copy, Locale } from "@/lib/copy";
import type { MyMessage, MyMessages } from "@/lib/data";
import { Badge, Button, Card } from "./primitives";
import { MESSAGES_ARRIVED_EVENT, MESSAGES_CHANGED_EVENT } from "./MessageCenter";
import { MessageWithdraw } from "./MessageWithdraw";
import { fmtDateTimeShort } from "@/lib/time";

const HEADERS = { "content-type": "application/json", "x-cma-request": "1" } as const;
type Permission = "unsupported" | "default" | "granted" | "denied";

/** The browser's notification permission as an external store: unsupported on the server, so the first render matches */
const permissionListeners = new Set<() => void>();
const permissionStore = {
  subscribe(cb: () => void) {
    permissionListeners.add(cb);
    return () => permissionListeners.delete(cb);
  },
  get(): Permission {
    return typeof Notification === "undefined" ? "unsupported" : (Notification.permission as Permission);
  },
  server: (): Permission => "unsupported",
  changed() {
    for (const cb of permissionListeners) cb();
  },
};

/** Thu 12 Oct, 14:05 in the viewer's zone, the same text on the server and in the browser (lib/time) */
function fmtWhen(instant: string, timeZone: string, locale: Locale): string {
  return fmtDateTimeShort(instant, timeZone, locale);
}

export function Inbox({ initial, copy, timeZone, locale, canWithdraw = false }: {
  initial: MyMessages; copy: Copy["messages"]; timeZone: string; locale: Locale;
  /** The viewer holds messages.withdraw: each message carries Delete */
  canWithdraw?: boolean;
}) {
  const [list, setList] = useState<MyMessage[]>(initial.messages);
  const permission = useSyncExternalStore(permissionStore.subscribe, permissionStore.get, permissionStore.server);
  const [pending, startTransition] = useTransition();
  /** A mark-read or acknowledge that was refused or did not arrive: said in words, never silent (the IT audit of 17 October 2026) */
  const [writeFailed, setWriteFailed] = useState(false);
  const unread = list.filter((m) => m.readAt === null).length;

  useEffect(() => {
    const refresh = async () => {
      const res = await fetch(`/api/v1/me/messages?limit=${initial.messages.length < 50 ? 50 : initial.messages.length}`, { cache: "no-store" });
      if (!res.ok) return;
      const { data } = (await res.json()) as { data: MyMessages };
      setList(data.messages);
    };
    window.addEventListener(MESSAGES_ARRIVED_EVENT, refresh);
    return () => window.removeEventListener(MESSAGES_ARRIVED_EVENT, refresh);
  }, [initial.messages.length]);

  function markRead(ids: string[]) {
    if (!ids.length) return;
    setWriteFailed(false);
    startTransition(async () => {
      const res = await fetch("/api/v1/me/messages/read", { method: "POST", headers: HEADERS, body: JSON.stringify({ ids }) }).catch(() => null);
      if (res?.ok) {
        const now = new Date().toISOString();
        setList((l) => l.map((m) => (ids.includes(m.id) && m.readAt === null ? { ...m, deliveredAt: m.deliveredAt ?? now, readAt: now } : m)));
      } else {
        setWriteFailed(true);
      }
      window.dispatchEvent(new Event(MESSAGES_CHANGED_EVENT));
    });
  }

  function acknowledge(id: string) {
    setWriteFailed(false);
    startTransition(async () => {
      const res = await fetch(`/api/v1/me/messages/${id}/ack`, { method: "POST", headers: HEADERS }).catch(() => null);
      if (res?.ok) {
        const now = new Date().toISOString();
        setList((l) => l.map((m) => (m.id === id ? { ...m, deliveredAt: m.deliveredAt ?? now, readAt: m.readAt ?? now, acknowledgedAt: now } : m)));
      } else {
        setWriteFailed(true);
      }
      window.dispatchEvent(new Event(MESSAGES_CHANGED_EVENT));
    });
  }

  async function askNotifications() {
    if (typeof Notification === "undefined") return;
    await Notification.requestPermission();
    permissionStore.changed();
  }

  return (
    <>
      <div className="mb-4 flex items-center justify-between gap-4">
        <p className="text-body text-p4a-muted" data-testid="inbox-unread-line">
          {unread === 0 ? copy.allRead : unread === 1 ? copy.unreadOne : copy.unread.replace("{n}", String(unread))}
        </p>
        <div className="flex items-center gap-3">
          {permission === "default" ? (
            <Button variant="outlined" size="sm" onClick={() => void askNotifications()} title={copy.notificationsHint}>{copy.notifications}</Button>
          ) : permission === "granted" ? (
            <span className="text-small text-p4a-muted">{copy.notificationsOn}</span>
          ) : permission === "denied" ? (
            <span className="text-small text-p4a-muted">{copy.notificationsBlocked}</span>
          ) : null}
          <Button variant="outlined" size="sm" onClick={() => markRead(list.filter((m) => m.readAt === null).map((m) => m.id))} disabled={pending || unread === 0} data-shortcut="m" shortcut="M">
            {copy.markAllRead}
          </Button>
        </div>
      </div>
      {writeFailed ? (
        <p role="alert" className="mb-4 text-small text-p4a-body" data-testid="inbox-write-failed">
          {copy.writeFailed}
        </p>
      ) : null}

      {list.length === 0 ? (
        <Card><p className="text-body text-p4a-muted">{copy.empty}</p></Card>
      ) : (
        <ul className="flex flex-col gap-3" data-testid="inbox-list">
          {list.map((m) => {
            const isUnread = m.readAt === null;
            const needsAck = m.urgency === "urgent" && m.acknowledgedAt === null;
            return (
              <li key={m.id} data-testid="inbox-item" data-unread={isUnread ? "true" : "false"}>
                <Card className={isUnread ? "border-l-4 border-l-p4a-deepblue" : ""}>
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge tone={m.kind === "alert" ? "info" : "neutral"}>{m.kind === "alert" ? copy.alert : copy.announcement}</Badge>
                        {m.urgency === "urgent" ? <Badge tone="warning">{copy.urgent}</Badge> : null}
                        {m.acknowledgedAt ? <Badge tone="success">{copy.acknowledged}</Badge> : null}
                        <span className="text-caption text-p4a-grey tabular">{fmtWhen(m.createdAt, timeZone, locale)}</span>
                      </div>
                      <p className={`mt-2 text-body ${isUnread ? "font-semibold text-p4a-heading" : "text-p4a-body"}`}>{m.title}</p>
                      {m.body ? <p className="mt-1 text-small text-p4a-body">{m.body}</p> : null}
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-2">
                      {m.ref?.url ? (
                        <a
                          href={m.ref.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          onClick={() => { if (isUnread) markRead([m.id]); }}
                          className="inline-flex h-8 items-center gap-2 rounded-button border border-p4a-deepblue px-3 text-small font-semibold text-p4a-deepblue no-underline hover:bg-p4a-bgblue"
                        >
                          {copy.openRecord} <span aria-hidden="true">↗</span>
                        </a>
                      ) : null}
                      {needsAck ? (
                        <Button variant="primary" size="sm" onClick={() => acknowledge(m.id)} disabled={pending}>{copy.acknowledge}</Button>
                      ) : isUnread && !m.ref?.url ? (
                        <Button variant="text" size="sm" onClick={() => markRead([m.id])} disabled={pending}>{copy.toastOpen}</Button>
                      ) : null}
                      {canWithdraw ? (
                        <MessageWithdraw id={m.id} title={m.title} copy={copy} onWithdrawn={() => setList((l) => l.filter((x) => x.id !== m.id))} />
                      ) : null}
                    </div>
                  </div>
                </Card>
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}
