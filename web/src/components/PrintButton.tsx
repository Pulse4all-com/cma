"use client";

import { Button } from "./primitives";

/** Opens the browser's print dialog (paper, or Save as file for a PDF); hidden on paper by its parent */
export function PrintButton({ label }: { label: string }) {
  return (
    <Button variant="primary" shortcut="X" data-shortcut="x" onClick={() => window.print()}>
      {label}
    </Button>
  );
}
