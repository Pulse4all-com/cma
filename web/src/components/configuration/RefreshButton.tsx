"use client";

/**
 * A refresh control instead of a poll (System health, addition 0008r): the page is read once per visit and
 * again on this button; router.refresh() re-renders the server component with the current state. The
 * button shows the pending state while the transition runs and names it for assistive tech.
 */
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { Button } from "../primitives";

export function RefreshButton({ label, pendingLabel }: { label: string; pendingLabel: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <Button variant="outlined" size="md" aria-busy={pending} disabled={pending} onClick={() => start(() => router.refresh())} data-testid="health-refresh">
      {pending ? pendingLabel : label}
    </Button>
  );
}
