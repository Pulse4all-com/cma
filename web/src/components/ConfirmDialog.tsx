"use client";

/**
 * Native <dialog> confirmation. Esc closes it (built in). Calm wording: what happens, what comes next.
 *
 * An ordinary confirmation opens on its confirm button, so Enter confirms. An irreversible one (it
 * removes data or changes it for good: README Decision log, 13 October 2026) opens on Cancel; Enter
 * activates only the focused button, so Enter at open cancels, and the confirm button is a
 * destructive secondary action without a keycap, never the primary one.
 */
import { useEffect, useRef, type ReactNode } from "react";
import { Button } from "./primitives";

export function ConfirmDialog({
  open,
  title,
  children,
  confirmLabel,
  cancelLabel,
  onConfirm,
  onCancel,
  busy = false,
  irreversible = false,
}: {
  open: boolean;
  title: string;
  children: ReactNode;
  confirmLabel: string;
  cancelLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
  busy?: boolean;
  irreversible?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) {
      d.showModal();
      // showModal focuses the first button, the confirm button; an irreversible change starts on Cancel
      if (irreversible) d.querySelector<HTMLButtonElement>("[data-confirm-cancel]")?.focus();
    }
    if (!open && d.open) d.close();
  }, [open, irreversible]);

  return (
    <dialog
      ref={ref}
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onCancel();
      }}
      className="m-auto w-[32rem] rounded-card border border-p4a-border bg-white p-6 text-p4a-body shadow-[0_1px_2px_rgba(11,19,61,0.06)] backdrop:bg-p4a-inkt/30"
    >
      <h2 className="text-panel font-semibold text-p4a-heading">{title}</h2>
      <div className="mt-2 text-body">{children}</div>
      <div className="mt-6 flex gap-3">
        {irreversible ? (
          <Button variant="destructive" size="md" onClick={onConfirm} disabled={busy} data-confirm="irreversible">
            {confirmLabel}
          </Button>
        ) : (
          <Button variant="primary" size="md" onClick={onConfirm} disabled={busy} autoFocus shortcut="Enter">
            {confirmLabel}
          </Button>
        )}
        <Button variant="outlined" size="md" onClick={onCancel} disabled={busy} shortcut="Esc" data-confirm-cancel="">
          {cancelLabel}
        </Button>
      </div>
    </dialog>
  );
}
