"use client";

import { useEffect, useState } from "react";
import { SESSION_EXPIRED_EVENT, sessionExpired } from "@/lib/client-fetch";
import type { Copy } from "@/lib/copy";
import { Button } from "./primitives";

/**
 * The notice of a sign-in that ended (brief N07, WP8): a request of this tab was answered 401 (src/lib/client-fetch.ts),
 * so the polls have stopped and a write would not reach the Workspace. A calm card says so and offers one step, signing
 * in again, which reloads the page through IAP on a click; never by itself. It is announced (role alert) without taking
 * the focus from what the person is doing, and stands at the top right, below the top bar, clear of the message toasts
 * at the bottom right (MessageCenter). Mounted once in the root layout; renders nothing until the event.
 */
export function SessionExpiredNotice({ copy }: { copy: Copy["sessionExpired"] }) {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    const on = () => setShown(true);
    if (sessionExpired()) on();
    window.addEventListener(SESSION_EXPIRED_EVENT, on);
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, on);
  }, []);
  if (!shown) return null;
  return (
    <div
      role="alert"
      data-testid="session-expired"
      className="fixed right-6 top-[calc(var(--spacing-topbar)+24px)] z-50 w-96 rounded-card border border-p4a-border bg-white p-6 shadow-[0_1px_2px_rgba(11,19,61,0.06)]"
    >
      <h2 className="text-panel font-semibold text-p4a-deepblue">{copy.title}</h2>
      <p className="mt-2 text-body">{copy.body}</p>
      <Button className="mt-4" onClick={() => window.location.reload()}>{copy.reload}</Button>
    </div>
  );
}
