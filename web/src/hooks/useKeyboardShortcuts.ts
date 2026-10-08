"use client";

/**
 * Keyboard-first: any element with data-shortcut="x" is activated by pressing
 * that key. Declarative, so a page adds a shortcut by adding an attribute and
 * the Keycap next to the label stays truthful.
 *
 * Rules: plain keys only (no modifiers), nothing while typing in a field (Esc
 * leaves the field so the shortcuts come back), and while a dialog is open only
 * its own shortcuts count.
 */
import { useEffect } from "react";

const typingTags = new Set(["INPUT", "TEXTAREA", "SELECT"]);

export function useKeyboardShortcuts() {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      const typing = !!target && (typingTags.has(target.tagName) || target.isContentEditable);
      if (typing && e.key === "Escape" && !document.querySelector("dialog[open]")) {
        target.blur();
        return;
      }
      if (typing || e.key.length !== 1) return;

      const key = e.key.toLowerCase();
      const scope = document.querySelector<HTMLElement>("dialog[open]") ?? document;
      // A page's own control with the letter wins over the rail's (the Configuration group's C
      // yields to Copy previous week and Custom range), so a page never loses a shortcut it shows
      const el = scope.querySelector<HTMLElement>(`main [data-shortcut="${key}"]`) ?? scope.querySelector<HTMLElement>(`[data-shortcut="${key}"]`);
      if (!el) return;
      e.preventDefault();
      el.focus();
      el.click();
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
}
