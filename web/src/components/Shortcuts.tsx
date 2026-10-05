"use client";

import { useKeyboardShortcuts } from "@/hooks/useKeyboardShortcuts";

/** Mounted once in the Shell; renders nothing */
export function Shortcuts() {
  useKeyboardShortcuts();
  return null;
}
