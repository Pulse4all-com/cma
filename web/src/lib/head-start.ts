/**
 * A head start for a page's reads (Reports → Dashboard, 12 November 2026): the reads start side by side and the page
 * waits for them up to a deadline. A read that is in by then is drawn with the page, with no outline in between; one
 * still on its way streams in behind its outline, in a boundary of its own. So a short period arrives whole, and a
 * long one shows what it has while the dear reads finish.
 *
 * Why not always stream: React shows a part no sooner than about 300 ms after the outline it replaces, so a read that
 * takes 30 ms would land later behind an outline than drawn with the page. Why not always wait: the slowest read would hold
 * everything back, which is what the page did before.
 */

/** A read at the deadline: its answer, or the promise still on its way */
export type Head<T> = { ready: true; value: T } | { ready: false; read: Promise<T> };

/**
 * How long Reports → Dashboard waits for its reads before it draws what it has (ms). 300, because waiting that long
 * costs nothing: while a part is still on its way React shows nothing new sooner than about 300 ms anyway (on a load
 * the route skeleton is on the screen and is replaced no sooner than that; on a click between periods the new page with
 * its outlines is held back as long: measured, 12 November 2026, the frame at about 330 ms with a head start of 200 and
 * of 300 alike). So a read of up to 300 ms arrives whole instead of behind an outline, where it would show 300 ms
 * later still. A click is answered by the link's pending mark meanwhile
 */
export const DASHBOARD_HEAD_MS = 300;

/** The Dashboard's parts, each with a read of its own: the time per status, the Intake row's counts, the speed to lead */
export const DASHBOARD_PARTS = ["time", "counts", "speed"] as const;

/**
 * A hint's words while its numbers are on their way: the text in parts, each {placeholder} a blank of a number's
 * width ("00", a share "00%", a duration "00h 00m"), which the page draws invisible. So the outline's lines wrap where
 * the figures' lines will, and nothing that is not read is shown, not even a dash that could be taken for a value
 */
export function blankNumbers(text: string): { text: string; blank: boolean }[] {
  const widths: Record<string, string> = { pct: "00%", time: "00h 00m" };
  return text.split(/(\{[a-z]+\})/).filter((part) => part !== "").map((part) => {
    const key = /^\{([a-z]+)\}$/.exec(part)?.[1];
    return key === undefined ? { text: part, blank: false } : { text: widths[key] ?? "00", blank: true };
  });
}

/** A deadline to share between the reads of one request */
export function deadlineIn(ms: number): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

/**
 * The read as it stands when the deadline passes. A read that fails before the deadline fails here, as an awaited read
 * would; one that fails later fails where it is awaited (its boundary)
 */
export async function headStart<T>(read: Promise<T>, deadline: Promise<void>): Promise<Head<T>> {
  const late = Symbol("late");
  // a failure after the deadline belongs to whoever awaits the read then: it must not count as unhandled here
  read.catch(() => undefined);
  const first = await Promise.race([read, deadline.then(() => late)]);
  return first === late ? { ready: false, read } : { ready: true, value: first as T };
}
