/**
 * Today, this week, this month and a custom range, with T, W, M and C as shortcuts. A server
 * component: every choice is a plain link or a GET form, so the period lives in the URL.
 */
import Link from "next/link";
import type { Copy } from "@/lib/copy";
import type { HoursRange } from "@/lib/data";
import { RANGE_KEYS, RANGES, type Range } from "@/lib/period";
import { Keycap } from "./primitives";

export function PeriodBar({
  pathname,
  range,
  period,
  today,
  copy,
  keep = {},
}: {
  pathname: "/hours" | "/team/hours";
  range: Range;
  period: HoursRange;
  today: string;
  copy: Copy;
  /** Other query values to carry along, such as a person filter */
  keep?: Record<string, string>;
}) {
  const labels: Record<Range, string> = {
    today: copy.myHours.today,
    week: copy.myHours.week,
    month: copy.myHours.month,
    custom: copy.myHours.custom,
  };
  const field =
    "h-10 rounded-input border border-p4a-border bg-white px-3 font-normal text-p4a-body focus:border-p4a-deepblue";

  return (
    <>
      <nav aria-label={copy.myHours.title} className="mb-6 flex gap-2">
        {RANGES.map((k) => (
          <Link
            key={k}
            href={{ pathname, query: { ...keep, range: k } }}
            aria-current={k === range ? "page" : undefined}
            data-shortcut={RANGE_KEYS[k].toLowerCase()}
            className={[
              "inline-flex h-10 items-center gap-2 rounded-button border px-4 text-body font-semibold",
              k === range
                ? "border-p4a-deepblue bg-p4a-deepblue text-white"
                : "border-p4a-border text-p4a-deepblue hover:bg-p4a-bgblue",
            ].join(" ")}
          >
            {labels[k]}
            <Keycap>{RANGE_KEYS[k]}</Keycap>
          </Link>
        ))}
      </nav>

      {range === "custom" ? (
        <form method="get" action={pathname} className="mb-6 flex items-end gap-4">
          <input type="hidden" name="range" value="custom" />
          {Object.entries(keep).map(([k, v]) => (
            <input key={k} type="hidden" name={k} value={v} />
          ))}
          <label className="flex flex-col gap-2 text-small font-semibold">
            {copy.myHours.from}
            <input type="date" name="from" defaultValue={period.from} max={today} autoFocus className={field} />
          </label>
          <label className="flex flex-col gap-2 text-small font-semibold">
            {copy.myHours.to}
            <input type="date" name="to" defaultValue={period.to} max={today} className={field} />
          </label>
          <button type="submit" className="h-10 rounded-button bg-p4a-deepblue px-4 font-semibold text-white hover:bg-p4a-denim">
            {copy.myHours.show}
          </button>
        </form>
      ) : null}
    </>
  );
}
