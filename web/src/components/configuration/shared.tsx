"use client";

/**
 * What the five configuration screens share: the write helper (same header and cross-site rules
 * as every other write), the refusal messages per HTTP status, a save note, the field classes,
 * and a native <dialog> form shell with Ctrl+Enter to save and Esc to close.
 */
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import type { Copy } from "@/lib/copy";
import { Button, Notice } from "../primitives";

export const field = "h-10 rounded-input border border-p4a-border bg-white px-3 text-body text-p4a-body focus:border-p4a-deepblue";
export const label = "flex flex-col gap-2 text-small font-semibold text-p4a-body";
export const th = "h-10 whitespace-nowrap px-3 text-left font-semibold";
export const td = "border-t border-p4a-border px-3 py-2 align-middle";

export type SaveState = { kind: "idle" } | { kind: "saving" } | { kind: "saved" } | { kind: "problem"; message: string };

/** One write to a configuration route; the answer's status decides the message, never its SQL */
export async function send(method: "PUT" | "POST", path: string, body?: unknown): Promise<Response> {
  return fetch(path, {
    method,
    headers: { "content-type": "application/json", "x-cma-request": "1" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

/** The message for a refused write; a screen may map 409 to its own rule first */
export function refusalMessage(status: number, c: Copy["configuration"], conflict?: string): string {
  if (status === 403) return c.notPermitted;
  if (status === 404) return c.notFound;
  if (status === 409 && conflict) return conflict;
  if (status === 400 || status === 409) return c.invalid;
  return c.notSaved;
}

/** Runs a write, shows its state and re-reads the page on success, so the table shows the database's answer */
export function useSave(c: Copy["configuration"]) {
  const router = useRouter();
  const [state, setState] = useState<SaveState>({ kind: "idle" });
  async function save(run: () => Promise<Response>, conflict?: string): Promise<boolean> {
    setState({ kind: "saving" });
    try {
      const res = await run();
      if (!res.ok) {
        setState({ kind: "problem", message: refusalMessage(res.status, c, conflict) });
        return false;
      }
      setState({ kind: "saved" });
      router.refresh();
      return true;
    } catch {
      setState({ kind: "problem", message: c.notSaved });
      return false;
    }
  }
  return { state, save, reset: () => setState({ kind: "idle" }) };
}

export function SaveNote({ state, c }: { state: SaveState; c: Copy["configuration"] }) {
  if (state.kind === "idle") return null;
  if (state.kind === "problem") return <Notice tone="warning">{state.message}</Notice>;
  return (
    <p role="status" className="text-small text-p4a-muted">
      {state.kind === "saving" ? c.saving : c.saved}
    </p>
  );
}

/** A native dialog with a form: mounted per opening (the parent gives it a key), Ctrl+Enter saves, Esc closes */
export function FormDialog({
  title,
  intro,
  onSave,
  onClose,
  busy,
  saveLabel,
  cancelLabel,
  children,
  wide = false,
}: {
  title: string;
  intro?: string;
  onSave: () => void;
  onClose: () => void;
  busy: boolean;
  saveLabel: string;
  cancelLabel: string;
  children: ReactNode;
  wide?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (d && !d.open) d.showModal();
    d?.querySelector<HTMLElement>("input, select, textarea")?.focus();
  }, []);
  return (
    <dialog
      ref={ref}
      className={`m-auto ${wide ? "w-[44rem]" : "w-[32rem]"} max-w-[calc(100vw-4rem)] rounded-card border border-p4a-border bg-white p-0 text-p4a-body backdrop:bg-p4a-inkt/40`}
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onClose();
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          onSave();
        }
      }}
    >
      <div className="flex flex-col gap-6 p-6">
        <header>
          <h2 className="text-panel font-semibold text-p4a-heading">{title}</h2>
          {intro ? <p className="mt-1 text-small text-p4a-muted">{intro}</p> : null}
        </header>
        {children}
        <div className="flex gap-3">
          <Button variant="primary" onClick={onSave} disabled={busy} shortcut="Ctrl+Enter">
            {saveLabel}
          </Button>
          <Button variant="outlined" onClick={onClose} disabled={busy} shortcut="Esc">
            {cancelLabel}
          </Button>
        </div>
      </div>
    </dialog>
  );
}

/** A yes-or-no with its one-line meaning, so the flags explain themselves (statuses, absence types) */
export function FlagField({ name, hint, checked, onChange, disabled }: { name: string; hint?: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className="flex items-start gap-3 text-body">
      <input type="checkbox" className="mt-1 h-4 w-4" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span>
        <span className="font-semibold">{name}</span>
        {hint ? <span className="text-p4a-muted"> · {hint}</span> : null}
      </span>
    </label>
  );
}
