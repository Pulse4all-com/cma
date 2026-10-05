"use client";

/**
 * Native <dialog> confirmation. Esc closes it (built in), Enter activates the
 * focused confirm button. Calm wording: what happens, what comes next.
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
}: {
  open: boolean;
  title: string;
  children: ReactNode;
  confirmLabel: string;
  cancelLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
  busy?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

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
        <Button variant="primary" size="md" onClick={onConfirm} disabled={busy} autoFocus shortcut="Enter">
          {confirmLabel}
        </Button>
        <Button variant="outlined" size="md" onClick={onCancel} disabled={busy} shortcut="Esc">
          {cancelLabel}
        </Button>
      </div>
    </dialog>
  );
}
