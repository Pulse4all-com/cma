"use client";

/**
 * The Invitations section of People (addition 0008l): the invitations the caller may see, open and
 * expired first with New link and Revoke, then accepted (who, when) and revoked (who, when). New link
 * opens the link dialog with the new token; Revoke needs a second tap on the same button, and Esc or
 * leaving the button disarms it. After a change the page re-reads itself, so the list shows the
 * database's answer. No token is ever listed: a link exists only in the answer that made it.
 */
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import type { Invitation, InvitationLink } from "@/lib/data";
import { invitationActionable, sortInvitations } from "@/lib/invitations";
import { fmtDateTime } from "@/lib/time";
import { HeaderHint } from "./HeaderHint";
import { HintLabel } from "./HintLabel";
import { InviteDialog, type InviteContext, type InviteDialogMode } from "./InviteDialog";
import { Badge, Button, Notice } from "./primitives";

const TONE = { open: "info", expired: "warning", accepted: "success", revoked: "neutral" } as const;

export function InvitationsSection({ invitations, context, copy }: { invitations: Invitation[]; context: InviteContext; copy: Copy }) {
  const t = copy.invitations;
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [armed, setArmed] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<{ n: number; mode: InviteDialogMode } | null>(null);
  const when = (iso: string) => fmtDateTime(iso, context.timeZone, context.screenLocale);
  const stateLabel = { open: t.stateOpen, expired: t.stateExpired, accepted: t.stateAccepted, revoked: t.stateRevoked };
  const rows = sortInvitations(invitations);
  const th = "h-10 whitespace-nowrap px-3 text-left font-semibold";

  async function post(path: string): Promise<Response> {
    return fetch(path, { method: "POST", headers: { "content-type": "application/json", "x-cma-request": "1" }, body: "{}" });
  }

  function renew(i: Invitation) {
    setError(null);
    startTransition(async () => {
      const res = await post(`/api/v1/team/invitations/${i.invitationId}/renew`);
      if (!res.ok) {
        setError(res.status === 409 ? t.conflict : res.status === 403 ? t.notPermitted : t.actionFailed);
        return;
      }
      const link = (await res.json()).data as InvitationLink;
      setDialog((d) => ({
        n: (d?.n ?? 0) + 1,
        mode: { kind: "link", link, invitation: { email: i.email, displayName: i.displayName, locale: i.locale, roleName: i.roleName } },
      }));
    });
  }

  function revoke(i: Invitation) {
    if (armed !== i.invitationId) {
      setArmed(i.invitationId);
      return;
    }
    setArmed(null);
    setError(null);
    startTransition(async () => {
      const res = await post(`/api/v1/team/invitations/${i.invitationId}/revoke`);
      if (!res.ok) setError(res.status === 403 ? t.notPermitted : t.actionFailed);
      router.refresh();
    });
  }

  return (
    <section className="rounded-card border border-p4a-border bg-white p-6" data-testid="invitations" onKeyDown={(e) => { if (e.key === "Escape") setArmed(null); }}>
      <h2 className="text-panel font-semibold text-p4a-heading">{t.title}</h2>
      <p className="mt-1 mb-4 max-w-3xl text-small text-p4a-muted">{t.intro}</p>
      {error ? <div className="mb-4"><Notice tone="warning">{error}</Notice></div> : null}
      {rows.length === 0 ? (
        <p className="text-body text-p4a-muted">{t.empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-body" data-testid="invitations-table">
            <thead className="bg-p4a-bgblue text-small text-p4a-heading">
              <tr>
                <th className={th}>{t.colPerson}</th>
                <th className={th}>{t.colRole}</th>
                <th className={th}><HintLabel label={t.colState}><HeaderHint label={copy.hints.about.replace("{label}", t.colState)} text={t.hintState} /></HintLabel></th>
                <th className={th}>{t.colSent}</th>
                <th className={th}><HintLabel label={t.colExpires}><HeaderHint label={copy.hints.about.replace("{label}", t.colExpires)} text={t.hintExpires} /></HintLabel></th>
                <th className={th}><span className="sr-only">{t.newLink}</span></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((i) => (
                <tr key={i.invitationId} data-testid="invitation-row" className="border-b border-p4a-border odd:bg-p4a-offwhite hover:bg-p4a-bgblue/50">
                  <td className="px-3 py-2 align-top">
                    <div className="font-semibold">{i.displayName}</div>
                    <div className="text-caption text-p4a-grey">{i.email}</div>
                  </td>
                  <td className="px-3 py-2 align-top">
                    {i.roleName}
                    <div className="text-caption text-p4a-grey">{i.organisationName}</div>
                  </td>
                  <td className="px-3 py-2 align-top"><Badge tone={TONE[i.state]}>{stateLabel[i.state]}</Badge></td>
                  <td className="px-3 py-2 align-top text-small">{t.sentBy.replace("{when}", when(i.renewedAt ?? i.createdAt)).replace("{who}", i.createdByName)}</td>
                  <td className="px-3 py-2 align-top text-small">
                    {i.state === "accepted" && i.acceptedAt
                      ? t.acceptedBy.replace("{who}", i.acceptedName ?? "").replace("{when}", when(i.acceptedAt))
                      : i.state === "revoked" && i.revokedAt
                        ? t.revokedBy.replace("{who}", i.revokedByName ?? "").replace("{when}", when(i.revokedAt))
                        : when(i.expiresAt)}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-right align-top">
                    {invitationActionable(i) ? (
                      <span className="inline-flex gap-2">
                        <Button variant="outlined" size="sm" disabled={pending} onClick={() => renew(i)}>{t.newLink}</Button>
                        <Button variant="destructive" size="sm" disabled={pending} data-testid="invitation-revoke"
                          onClick={() => revoke(i)} onBlur={() => setArmed((a) => (a === i.invitationId ? null : a))}>
                          {armed === i.invitationId ? t.revokeAgain : t.revoke}
                        </Button>
                      </span>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {dialog ? (
        <InviteDialog
          key={dialog.n}
          mode={dialog.mode}
          context={context}
          copy={copy}
          onClose={() => setDialog(null)}
          onDone={() => {
            setDialog(null);
            router.refresh();
          }}
        />
      ) : null}
    </section>
  );
}
