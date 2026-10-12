"use client";

/**
 * The explanation of a column header or tile label: a small info mark after the label (the line
 * icon set, Footnote Grey, 14 px) and a hint panel (role tooltip) that opens on hover and on keyboard
 * focus, opens and closes on a tap on touch screens, and closes on Esc. The mark is a button of its
 * own (its own tab stop) described by the panel, so a header that is a link or a sort control keeps
 * working as it does. The panel is placed below the header it explains (the closest th or
 * [data-hint-anchor]) when there is room, above it when there is not, and kept inside the viewport.
 * No library: the panel is fixed-positioned, so a table or card never clips it.
 */
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";

const GAP = 6;
const MARGIN = 8;

export function HeaderHint({ label, text }: { label: string; text: string }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLSpanElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLSpanElement>(null);
  /** The pointer of the last press: a tap toggles, a mouse hovers, the keyboard focuses */
  const pointer = useRef<string>("");
  const leaveTimer = useRef<number | undefined>(undefined);

  const place = useCallback(() => {
    const b = button.current;
    const p = panel.current;
    if (!b || !p) return;
    const anchor = (b.closest("th, [data-hint-anchor]") as HTMLElement | null) ?? b;
    const a = anchor.getBoundingClientRect();
    const m = b.getBoundingClientRect();
    const { width, height } = p.getBoundingClientRect();
    const below = a.bottom + GAP;
    const fitsBelow = below + height + MARGIN <= window.innerHeight;
    const top = fitsBelow ? below : Math.max(MARGIN, a.top - GAP - height);
    const left = Math.max(MARGIN, Math.min(m.left - 12, window.innerWidth - width - MARGIN));
    p.style.top = `${top}px`;
    p.style.left = `${left}px`;
    p.style.visibility = "visible";
  }, []);

  // Placed before the browser paints, so the panel never shows in the wrong place
  useLayoutEffect(() => {
    if (open) place();
    else if (panel.current) panel.current.style.visibility = "hidden";
  }, [open, place]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    const onDown = (e: PointerEvent) => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    const onMove = () => place();
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onDown);
    window.addEventListener("scroll", onMove, true);
    window.addEventListener("resize", onMove);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onDown);
      window.removeEventListener("scroll", onMove, true);
      window.removeEventListener("resize", onMove);
    };
  }, [open, place]);

  useEffect(() => () => window.clearTimeout(leaveTimer.current), []);

  const enter = (e: ReactPointerEvent) => {
    if (e.pointerType !== "mouse") return;
    window.clearTimeout(leaveTimer.current);
    setOpen(true);
  };
  const leave = (e: ReactPointerEvent) => {
    if (e.pointerType !== "mouse") return;
    // A short grace, so the pointer can move from the mark onto the panel; focus keeps it open
    leaveTimer.current = window.setTimeout(() => {
      if (document.activeElement !== button.current) setOpen(false);
    }, 120);
  };

  return (
    <span ref={wrap} className="relative z-10 inline-flex align-middle" onPointerEnter={enter} onPointerLeave={leave}>
      <button
        ref={button}
        type="button"
        aria-label={label}
        aria-describedby={id}
        data-header-hint=""
        className="ml-1 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-p4a-grey hover:text-p4a-deepblue"
        onPointerDown={(e) => { pointer.current = e.pointerType; }}
        onFocus={() => {
          // A tap focuses the button too; the click that follows decides
          if (pointer.current !== "touch" && pointer.current !== "pen") setOpen(true);
        }}
        onBlur={() => {
          pointer.current = "";
          setOpen(false);
        }}
        onClick={(e) => {
          // The mark sits inside a header or tile: its click is its own
          e.preventDefault();
          e.stopPropagation();
          if (pointer.current === "mouse") setOpen(true);
          else setOpen((o) => !o);
        }}
      >
        <svg
          aria-hidden="true"
          viewBox="0 0 20 20"
          className="h-3.5 w-3.5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.75"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <circle cx="10" cy="10" r="7.25" />
          <path d="M10 9v4.75" />
          <path d="M10 6.25h.01" />
        </svg>
      </button>
      <span
        ref={panel}
        id={id}
        role="tooltip"
        hidden={!open}
        data-hint-panel=""
        style={{ top: 0, left: 0, visibility: "hidden" }}
        className="fixed z-50 block w-max max-w-80 whitespace-normal rounded-button border border-p4a-border bg-white px-3 py-2 text-left text-small font-normal normal-case text-p4a-body"
      >
        {text}
      </span>
    </span>
  );
}
