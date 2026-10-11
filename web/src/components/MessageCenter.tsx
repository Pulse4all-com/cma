"use client";

/**
 * The message centre, mounted once in the Shell for every person (migration 0008): polls the own
 * inbox every 10 s while the tab is visible and every 30 s hidden (the README's fallback until the
 * realtime service is chosen), shows the unread count on the top-bar inbox and in the browser title,
 * a toast for every new message, a desktop notification while the tab is in the background (only
 * with the permission the person granted from the inbox, never asked on load), and the urgent
 * pop-up with a sound that has to be confirmed. References only: a toast carries the title, the body
 * and the record link, never customer data.
 */
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import type { Copy } from "@/lib/copy";
import type { MyMessage, MyMessages } from "@/lib/data";
import { arrivals, POLL_HIDDEN_MS, POLL_VISIBLE_MS, titleWithUnread, TOAST_MS } from "@/lib/messages";
import { Button } from "./primitives";

/** Fired by the inbox after it changed something, so the centre polls right away */
export const MESSAGES_CHANGED_EVENT = "cma-messages-changed";
/** Fired by the centre when a poll brought new messages, so an open inbox refreshes */
export const MESSAGES_ARRIVED_EVENT = "cma-messages-arrived";

const HEADERS = { "content-type": "application/json", "x-cma-request": "1" } as const;

/** One short tone for an alert that arrives (a new deal, an assignment), the chime for an urgent message */
function ping() {
  tones([[1046.5, 0]]);
}

/** Two short tones from the Web Audio API: no file to load, nothing to cache */
function chime() {
  tones([[880, 0], [1174.66, 0.25]]);
}

function tones(notes: [number, number][]) {
  try {
    const AudioCtx = window.AudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    const play = (freq: number, at: number) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = "sine";
      o.frequency.value = freq;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + at);
      g.gain.exponentialRampToValueAtTime(0.2, ctx.currentTime + at + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + at + 0.35);
      o.connect(g).connect(ctx.destination);
      o.start(ctx.currentTime + at);
      o.stop(ctx.currentTime + at + 0.4);
    };
    for (const [freq, at] of notes) play(freq, at);
    setTimeout(() => void ctx.close(), 1200);
  } catch {
    // No sound is not a failure: the pop-up still demands confirmation
  }
}

/** A desktop notification while the tab is in the background; clicking it focuses the tab and opens the message */
function notify(m: MyMessage, onOpen: (m: MyMessage) => void) {
  try {
    const n = new Notification(m.title, { body: m.body, tag: m.id });
    n.onclick = () => {
      window.focus();
      onOpen(m);
      n.close();
    };
  } catch {
    // Notifications are a convenience; the toast and the inbox still show the message
  }
}

export function MessageCenter({ copy, active }: { copy: Copy["messages"]; active: boolean }) {
  const router = useRouter();
  const [unread, setUnread] = useState<number | null>(null);
  const [toasts, setToasts] = useState<MyMessage[]>([]);
  const [urgent, setUrgent] = useState<MyMessage[]>([]);
  const [acking, setAcking] = useState(false);
  const known = useRef<Set<string>>(new Set());
  const since = useRef<string | null>(null);
  const first = useRef(true);
  const dialog = useRef<HTMLDialogElement>(null);
  // The latest open() for a notification's click, which fires long after the poll that created it
  const openRef = useRef<(m: MyMessage) => void>(() => {});

  const poll = useCallback(async () => {
    try {
      const url = since.current ? `/api/v1/me/messages?since=${encodeURIComponent(since.current)}` : "/api/v1/me/messages";
      const res = await fetch(url, { cache: "no-store" });
      if (!res.ok) return;
      const { data } = (await res.json()) as { data: MyMessages };
      // Unread is always the full count (older messages included), so the badge is right after the first poll
      setUnread(data.unreadCount);
      const newest = data.messages[0]?.createdAt;
      if (newest && (!since.current || newest > since.current)) since.current = newest;
      const got = arrivals(known.current, data.messages, first.current);
      first.current = false;
      if (got.toasts.length) {
        setToasts((t) => [...t, ...got.toasts]);
        // An alert (a new deal, an assignment) rings once; a plain message is silent
        if (got.toasts.some((m) => m.kind === "alert")) ping();
        if (document.hidden && typeof Notification !== "undefined" && Notification.permission === "granted") {
          for (const m of got.toasts) notify(m, (x) => openRef.current(x));
        }
        window.dispatchEvent(new Event(MESSAGES_ARRIVED_EVENT));
      }
      if (got.urgent.length) {
        setUrgent((u) => {
          const ids = new Set(u.map((x) => x.id));
          const fresh = got.urgent.filter((x) => !ids.has(x.id));
          if (fresh.length) chime();
          return fresh.length ? [...u, ...fresh] : u;
        });
      }
    } catch {
      // Network hiccup: the next tick tries again
    }
  }, []);

  // The poll loop follows the tab's visibility; a change event from the inbox polls at once
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | null = null;
    let stopped = false;
    const tick = async () => {
      await poll();
      if (stopped) return;
      timer = setTimeout(tick, document.hidden ? POLL_HIDDEN_MS : POLL_VISIBLE_MS);
    };
    const restart = () => {
      if (timer) clearTimeout(timer);
      void tick();
    };
    void tick();
    document.addEventListener("visibilitychange", restart);
    window.addEventListener(MESSAGES_CHANGED_EVENT, restart);
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
      document.removeEventListener("visibilitychange", restart);
      window.removeEventListener(MESSAGES_CHANGED_EVENT, restart);
    };
  }, [poll]);

  // The browser title carries the unread count (README, Features 1)
  useEffect(() => {
    if (unread === null) return;
    document.title = titleWithUnread(document.title, unread);
  }, [unread]);

  // A toast leaves on its own
  useEffect(() => {
    if (!toasts.length) return;
    const id = setTimeout(() => setToasts((t) => t.slice(1)), TOAST_MS);
    return () => clearTimeout(id);
  }, [toasts]);

  // The urgent pop-up: open while something is unconfirmed, and Esc does not close it
  useEffect(() => {
    const d = dialog.current;
    if (!d) return;
    if (urgent.length && !d.open) d.showModal();
    if (!urgent.length && d.open) d.close();
  }, [urgent]);

  async function markRead(ids: string[]) {
    await fetch("/api/v1/me/messages/read", { method: "POST", headers: HEADERS, body: JSON.stringify({ ids }) });
    window.dispatchEvent(new Event(MESSAGES_CHANGED_EVENT));
  }

  /** Opening a toast reads the message and follows its link in a new window, or goes to the inbox */
  async function open(m: MyMessage) {
    setToasts((t) => t.filter((x) => x.id !== m.id));
    const w = m.ref?.url ? window.open(m.ref.url, "_blank", "noopener,noreferrer") : null;
    await markRead([m.id]);
    if (!w) router.push("/messages");
  }

  async function acknowledge(m: MyMessage) {
    setAcking(true);
    try {
      const res = await fetch(`/api/v1/me/messages/${m.id}/ack`, { method: "POST", headers: HEADERS });
      if (res.ok || res.status === 404) setUrgent((u) => u.filter((x) => x.id !== m.id));
      window.dispatchEvent(new Event(MESSAGES_CHANGED_EVENT));
    } finally {
      setAcking(false);
    }
  }

  useEffect(() => {
    openRef.current = (m) => void open(m);
  });

  const current = urgent[0] ?? null;
  const badge = unread === null ? null : unread > 99 ? "99+" : String(unread);

  return (
    <>
      <Link
        href="/messages"
        title={copy.openInbox}
        aria-label={badge && unread ? `${copy.openInbox} · ${unread === 1 ? copy.unreadOne : copy.unread.replace("{n}", String(unread))}` : copy.openInbox}
        aria-current={active ? "page" : undefined}
        data-testid="inbox-link"
        className="relative inline-flex h-8 items-center gap-2 rounded-button px-2 text-p4a-body hover:bg-p4a-bgblue"
      >
        <svg aria-hidden="true" viewBox="0 0 20 20" className="h-5 w-5" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
          <path d="M3 11.5V15a1.5 1.5 0 0 0 1.5 1.5h11A1.5 1.5 0 0 0 17 15v-3.5" />
          <path d="M3 11.5 5.3 4.6A1 1 0 0 1 6.25 4h7.5a1 1 0 0 1 .95.6L17 11.5" />
          <path d="M3 11.5h4l1 2h4l1-2h4" />
        </svg>
        {badge && unread ? (
          <span data-testid="inbox-unread" className="inline-flex h-5 min-w-5 items-center justify-center rounded-button bg-p4a-deepblue px-1 text-caption font-semibold tabular text-white">
            {badge}
          </span>
        ) : null}
      </Link>

      {/* Toasts: bottom right, newest last, each opens the record or the inbox */}
      {toasts.length ? (
        <div role="status" aria-live="polite" className="fixed bottom-6 right-6 z-40 flex w-96 flex-col gap-3">
          {toasts.map((m) => (
            <div key={m.id} data-testid="message-toast" className="rounded-card border border-p4a-border bg-white p-4 shadow-[0_8px_24px_rgba(11,19,61,0.12)]">
              <p className="text-caption font-semibold uppercase tracking-wide text-p4a-muted">{m.kind === "alert" ? copy.alert : copy.announcement}</p>
              <p className="mt-1 text-body font-semibold text-p4a-heading">{m.title}</p>
              {m.body ? <p className="mt-1 text-small text-p4a-body">{m.body}</p> : null}
              <div className="mt-3 flex gap-3">
                <Button size="sm" variant="primary" onClick={() => void open(m)}>{m.ref?.url ? copy.openRecord : copy.toastOpen}</Button>
                <Button size="sm" variant="text" onClick={() => setToasts((t) => t.filter((x) => x.id !== m.id))}>×</Button>
              </div>
            </div>
          ))}
        </div>
      ) : null}

      {/* The urgent pop-up: one message at a time, confirmation required, Esc refused */}
      <dialog
        ref={dialog}
        data-testid="urgent-dialog"
        onCancel={(e) => e.preventDefault()}
        className="m-auto w-[32rem] rounded-card border-l-4 border-p4a-warning bg-white p-6 text-p4a-body shadow-[0_1px_2px_rgba(11,19,61,0.06)] backdrop:bg-p4a-inkt/40"
      >
        {current ? (
          <>
            <p className="text-caption font-semibold uppercase tracking-wide text-p4a-warning">{copy.urgentTitle}</p>
            <h2 className="mt-1 text-panel font-semibold text-p4a-heading">{current.title}</h2>
            {current.body ? <p className="mt-2 text-body">{current.body}</p> : null}
            <p className="mt-4 text-small text-p4a-muted">{copy.urgentBody}</p>
            <div className="mt-6 flex items-center gap-3">
              <Button variant="primary" size="md" onClick={() => void acknowledge(current)} disabled={acking} autoFocus data-shortcut="a" shortcut="A">
                {copy.acknowledge}
              </Button>
              {current.ref?.url ? (
                <a href={current.ref.url} target="_blank" rel="noopener noreferrer" className="inline-flex h-10 items-center gap-2 font-semibold text-p4a-deepblue hover:underline">
                  {copy.openRecord} <span aria-hidden="true">↗</span>
                </a>
              ) : null}
              {urgent.length > 1 ? <span className="ml-auto text-small text-p4a-muted tabular">1 / {urgent.length}</span> : null}
            </div>
          </>
        ) : null}
      </dialog>
    </>
  );
}
