"use client";

/**
 * Delete a message for everyone (addition 0008z, 20 October 2026), for people holding messages.withdraw: a Delete button
 * that asks first, Cancel focused (an irreversible change, README Decision log 13 October 2026), and withdraws the message
 * through POST /api/v1/messages/{id}/withdraw. The message keeps its row and its audit; no recipient sees it again and a
 * delivery not yet made never happens. A refusal or a lost request is said in words, never silent.
 */
import { useState } from "react";
import type { Copy } from "@/lib/copy";
import { ConfirmDialog } from "./ConfirmDialog";
import { MESSAGES_CHANGED_EVENT } from "./MessageCenter";
import { Button } from "./primitives";

const HEADERS = { "content-type": "application/json", "x-cma-request": "1" } as const;

export function MessageWithdraw({ id, title, copy, onWithdrawn }: {
  id: string;
  /** The message's title, for the button's accessible name */
  title: string;
  copy: Copy["messages"];
  onWithdrawn: (withdrawnAt: string) => void;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  async function withdraw() {
    setBusy(true);
    setFailed(false);
    const res = await fetch(`/api/v1/messages/${id}/withdraw`, { method: "POST", headers: HEADERS }).catch(() => null);
    setBusy(false);
    setAsking(false);
    if (res?.ok) {
      const { data } = (await res.json()) as { data: { withdrawnAt: string } };
      onWithdrawn(data.withdrawnAt);
      window.dispatchEvent(new Event(MESSAGES_CHANGED_EVENT));
    } else {
      setFailed(true);
    }
  }

  return (
    <>
      <Button variant="text" size="sm" onClick={() => setAsking(true)} aria-label={copy.deleteLabel.replace("{title}", title)} data-testid="message-delete">
        {copy.delete}
      </Button>
      {failed ? <p role="alert" className="text-small text-p4a-body" data-testid="message-delete-failed">{copy.deleteFailed}</p> : null}
      <ConfirmDialog open={asking} title={copy.deleteTitle} confirmLabel={copy.delete} cancelLabel={copy.cancel} irreversible busy={busy}
        onConfirm={() => void withdraw()} onCancel={() => setAsking(false)}>
        <p data-testid="message-delete-body">{copy.deleteBody}</p>
      </ConfirmDialog>
    </>
  );
}
