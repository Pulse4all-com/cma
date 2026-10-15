"use client";

/**
 * Preview as role (16 October 2026): the select in the top bar and the Exit button of the banner, for a
 * person whose real permissions hold users.manage_all (Principal.canPreview). Both post to
 * /api/v1/me/preview, which sets or clears the httpOnly cookie, and then refresh the page, so the server
 * renders the Welcome blocks, the rail and the page with the narrowed permissions (lib/auth/preview).
 * Focus on the select pauses the shortcuts as any select does; no shortcut letter tonight.
 */
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { Copy } from "@/lib/copy";
import { Button } from "./primitives";

const HEADERS = { "content-type": "application/json", "x-cma-request": "1" } as const;

async function postPreview(roleKey: string | null): Promise<boolean> {
  const res = await fetch("/api/v1/me/preview", { method: "POST", headers: HEADERS, body: JSON.stringify({ roleKey }) }).catch(() => null);
  return !!res?.ok;
}

export function PreviewSelect({
  roles,
  current,
  ownRoleName,
  copy,
}: {
  /** The tenant's roles but the person's own, as cma.roles() lists them */
  roles: { key: string; name: string }[];
  /** The previewed role key, or null for the own view */
  current: string | null;
  ownRoleName: string;
  copy: Copy["shell"];
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [failed, setFailed] = useState(false);
  // The select is remounted by its key: the server's answer after the refresh wins, and a refused
  // change puts the previous choice back
  const [attempt, setAttempt] = useState(0);

  function change(next: string) {
    start(async () => {
      const ok = await postPreview(next === "" ? null : next);
      setFailed(!ok);
      if (ok) router.refresh();
      else setAttempt((a) => a + 1);
    });
  }

  return (
    <label className="flex items-center gap-2 text-small text-p4a-muted">
      <span>{copy.previewAs}</span>
      <select
        key={`${current ?? ""}-${attempt}`}
        defaultValue={current ?? ""}
        onChange={(e) => change(e.target.value)}
        disabled={pending}
        data-testid="preview-select"
        className="h-8 rounded-input border border-p4a-border bg-white px-2 text-small text-p4a-body focus:border-p4a-deepblue"
      >
        <option value="">{copy.previewOwn.replace("{role}", ownRoleName)}</option>
        {roles.map((r) => (
          <option key={r.key} value={r.key}>{r.name}</option>
        ))}
      </select>
      {failed ? <span role="alert" className="text-caption text-p4a-error">{copy.previewFailed}</span> : null}
    </label>
  );
}

export function ExitPreview({ copy }: { copy: Copy["shell"] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [failed, setFailed] = useState(false);
  return (
    <span className="flex items-center gap-3">
      {failed ? <span role="alert" className="text-caption text-p4a-error">{copy.previewFailed}</span> : null}
      <Button
        variant="outlined"
        size="sm"
        disabled={pending}
        data-testid="exit-preview"
        onClick={() =>
          start(async () => {
            const ok = await postPreview(null);
            setFailed(!ok);
            if (ok) router.refresh();
          })
        }
      >
        {copy.exitPreview}
      </Button>
    </span>
  );
}
