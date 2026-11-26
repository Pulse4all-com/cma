"use client";

/**
 * The Assignment and Hours market dropdowns of the planner's Day view and its bar dialog (Martin, 26 November 2026): every
 * active assignment type in the tenant's order, work types first, then pauses, then the extra types (lib/assignments,
 * pickerOrder), each as its colour swatch, code and name, so nobody needs to know a code by heart. Typing filters the list
 * (a code that starts with the text, a name that holds it); CODE and CODE-MARKET still work for whoever knows them, and
 * Enter takes the typed code, else the highlighted type. Next to it the Hours market: Own market (the default) and the
 * tenant's active hours markets; disabled for a pause, which has no market (0009zz).
 *
 * A combobox per the ARIA pattern: the input owns the list (aria-controls, aria-activedescendant), the arrows move in it,
 * Enter chooses, Esc closes the list (a second Esc hands back to the caller), Tab leaves. The colour never carries meaning
 * alone: the code and the name are always text (Pulse4all-Style 7.8). Inline (the bar dialog): the list takes its place
 * in the dialog instead of floating over it, and opens on a click, typing or an arrow, not on focus.
 */
import { useId, useRef, useState, type RefObject } from "react";
import type { AssignmentType, HoursMarket } from "@/lib/data";
import { parseAssignment, pickerFilter, pickerOrder, toneOf, TONE_CLASS, type ParseProblem } from "@/lib/assignments";

export type Choice = { code: string | null; market: string | null };

export function AssignmentPicker({
  types, markets, value, onChange, onChoose, onEscape, onProblem, inputRef, labels, invalid = false, testId = "assignment-code", inline = false,
}: {
  types: readonly AssignmentType[];
  markets: readonly HoursMarket[];
  value: Choice;
  /** The type or market changed (the dropdowns follow it) */
  onChange: (v: Choice) => void;
  /** A type was chosen (a click, Enter) or the market changed with a type chosen: the caller may apply it at once */
  onChoose: (v: { code: string; market: string | null }) => void;
  /** Esc with the list closed: hand the keyboard back (the grid) */
  onEscape?: () => void;
  /** Typed text that names no type, or a market a pause cannot carry */
  onProblem: (p: ParseProblem | null) => void;
  inputRef?: RefObject<HTMLInputElement | null>;
  labels: { assignment: string; market: string; ownMarket: string; pauseNoMarket: string; placeholder: string; noMatch: string };
  invalid?: boolean;
  testId?: string;
  /** In a dialog: the list in the flow, opened on a click, typing or an arrow (not on focus) */
  inline?: boolean;
}) {
  const id = useId();
  const own = useRef<HTMLInputElement>(null);
  const input = inputRef ?? own;
  const ordered = pickerOrder(types);
  const current = types.find((t) => t.code === value.code) ?? null;
  const [text, setText] = useState<string | null>(null);   // null: the field shows the chosen code
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const options = pickerFilter(ordered, text ?? "");
  const isPause = current?.kind === "pause";

  function choose(code: string, market: string | null) {
    const type = types.find((t) => t.code === code);
    const m = type?.kind === "pause" ? null : market;
    setText(null);
    setOpen(false);
    onProblem(null);
    onChange({ code, market: m });
    onChoose({ code, market: m });
  }

  /** Enter: the typed CODE or CODE-MARKET when it is one; else the highlighted type with the market chosen */
  function enter() {
    const typed = (text ?? "").trim();
    if (typed === "") {
      if (open && options[active]) { choose(options[active]!.code, value.market); return; }
      if (value.code) { choose(value.code, value.market); return; }
      onProblem("empty");
      return;
    }
    const parsed = parseAssignment(typed, types.map((t) => ({ ...t })), markets);
    if (!("problem" in parsed)) { choose(parsed.code, parsed.market ?? value.market); return; }
    if ((parsed.problem === "unknown" || parsed.problem === "format") && options[active]) { choose(options[active]!.code, value.market); return; }
    onProblem(parsed.problem);
  }

  const listId = `${id}-list`;
  const optionId = (i: number) => `${id}-o${i}`;
  return (
    <div className={`flex flex-wrap gap-3 ${inline ? "items-start" : "items-end"}`}>
      <label className="relative flex flex-col gap-2 text-small font-semibold" htmlFor={`${id}-input`}>
        {labels.assignment}
        <span className={`relative flex ${inline ? "flex-col" : "items-center"}`}>
          {current && text === null ? (
            <span aria-hidden="true" className={`pointer-events-none absolute left-3 top-3 h-4 w-4 rounded-button ${TONE_CLASS[toneOf(current)]}`} />
          ) : null}
          <input
            id={`${id}-input`}
            ref={input}
            role="combobox"
            aria-expanded={open}
            aria-controls={listId}
            aria-autocomplete="list"
            aria-activedescendant={open && options[active] ? optionId(active) : undefined}
            aria-invalid={invalid || undefined}
            value={text ?? (current ? `${current.code}  ${current.name}` : "")}
            placeholder={labels.placeholder}
            maxLength={40}
            data-testid={testId}
            autoComplete="off"
            // a dropdown: it opens on focus and on a click, at the type chosen
            onFocus={(e) => { e.currentTarget.select(); setActive(Math.max(0, ordered.findIndex((o) => o.code === value.code))); if (!inline) setOpen(true); }}
            onClick={() => setOpen(true)}
            onChange={(e) => { setText(e.target.value); setActive(0); setOpen(true); onProblem(null); }}
            // leaving the field keeps what was typed when it names a type (CODE or CODE-MARKET), so Apply and Save use it
            // and never the earlier choice; text that names none is let go and says why
            onBlur={() => {
              setOpen(false);
              const typed = (text ?? "").trim();
              setText(null);
              if (typed === "") return;
              const parsed = parseAssignment(typed, types.map((t) => ({ ...t })), markets);
              if ("problem" in parsed) { onProblem(parsed.problem); return; }
              const type = types.find((t) => t.code === parsed.code);
              onChange({ code: parsed.code, market: type?.kind === "pause" ? null : parsed.market ?? value.market });
            }}
            onKeyDown={(e) => {
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                if (!open) { setOpen(true); setActive(Math.max(0, options.findIndex((o) => o.code === value.code))); return; }
                const n = options.length;
                if (n > 0) setActive((a) => (a + (e.key === "ArrowDown" ? 1 : n - 1)) % n);
                return;
              }
              if (e.key === "Enter") { e.preventDefault(); enter(); return; }
              if (e.key === "Escape") {
                // Esc closes the list or drops the typed text first; with nothing to close it goes on to the caller (the
                // grid takes the keyboard back) and, not prevented, to a dialog around it, which closes
                if (open || text !== null) { e.preventDefault(); setOpen(false); setText(null); onProblem(null); return; }
                onEscape?.();
              }
            }}
            className={`h-10 ${inline ? "w-56" : "w-72"} rounded-input border bg-white pr-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue ${current && text === null ? "pl-9" : "pl-3"} ${invalid ? "border-p4a-error" : "border-p4a-border"}`}
          />
          {open ? (
            <ul id={listId} role="listbox" aria-label={labels.assignment}
              className={`${inline ? "mt-1 max-h-60 w-full" : "absolute left-0 top-11 z-20 max-h-80 w-80"} overflow-y-auto rounded-input border border-p4a-border bg-white py-1 font-normal shadow-[0_1px_2px_rgba(11,19,61,0.06)]`}>
              {options.length === 0 ? <li className="px-3 py-2 text-small text-p4a-muted">{labels.noMatch}</li> : options.map((t, i) => (
                <li
                  key={t.code}
                  id={optionId(i)}
                  role="option"
                  aria-selected={i === active}
                  // keeps the focus in the field: a click chooses without a blur first
                  onPointerDown={(e) => { e.preventDefault(); choose(t.code, value.market); }}
                  onPointerEnter={() => setActive(i)}
                  className={`flex h-10 cursor-pointer items-center gap-3 px-3 text-body ${i === active ? "bg-p4a-bgblue" : ""}`}
                >
                  <span aria-hidden="true" className={`h-4 w-4 shrink-0 rounded-button ${TONE_CLASS[toneOf(t)]}`} />
                  <span className="tabular w-12 shrink-0 font-semibold">{t.code}</span>
                  <span className="truncate">{t.name}</span>
                </li>
              ))}
            </ul>
          ) : null}
        </span>
      </label>
      <label className="flex flex-col gap-2 text-small font-semibold">
        {labels.market}
        <select
          value={isPause ? "" : value.market ?? ""}
          disabled={isPause}
          data-testid={`${testId}-market`}
          onChange={(e) => {
            const market = e.target.value || null;
            onChange({ ...value, market });
            if (value.code) onChoose({ code: value.code, market });
          }}
          className="h-10 min-w-40 rounded-input border border-p4a-border bg-white px-3 font-normal text-body text-p4a-body focus:border-p4a-deepblue disabled:border-transparent disabled:bg-p4a-sand disabled:text-p4a-muted"
        >
          <option value="">{isPause ? labels.pauseNoMarket : labels.ownMarket}</option>
          {isPause ? null : markets.filter((m) => m.isActive || m.code === value.market).map((m) => <option key={m.code} value={m.code}>{m.code} · {m.name}</option>)}
        </select>
      </label>
    </div>
  );
}
