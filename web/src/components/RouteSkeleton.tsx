import { cookies } from "next/headers";
import { RAIL_COOKIE } from "@/lib/nav";

/**
 * The route skeleton (night N06, 5 November 2026): what a click shows within 100 ms, before the destination's data
 * is there. The page's frame as Shell draws it (the white top bar, the rail on Background Blue, the Sand content area)
 * with placeholder blocks where the title and the cards go, in the style guide's colours and radii (7.1, 7.3); no
 * spinner. Every route segment's loading.tsx renders it (except a page that must answer a real 404: a loading boundary
 * sends 200 before the page decides; the Live board keeps its boundary and accepts a soft 404, Decision log, 5 November
 * 2026), and the rail's links prefetch it, so the frame is on screen
 * while the page's reads run. It reads the rail's cookie, as the Shell does, so the frame comes up folded or expanded
 * in the person's state and nothing jumps when the page replaces it; no data.
 *
 * shape "liveBoard" (the Live board's UX pass, 10 November 2026): the board's own outline, the freshness line, four
 * panels of six figures (Inbound today, Outbound today, Follow-up now, the team's groups) and the people's rows, so the
 * wait reads as the board arriving and nothing moves when it does.
 */
export async function RouteSkeleton({ shape = "page" }: { shape?: "page" | "liveBoard" } = {}) {
  const collapsed = (await cookies()).get(RAIL_COOKIE)?.value === "collapsed";
  const bar = (w: string, h = "h-4") => <div className={`${h} ${w} animate-pulse rounded-input bg-p4a-border`} aria-hidden="true" />;
  return (
    <div
      data-route-skeleton
      data-rail={collapsed ? "collapsed" : "expanded"}
      className="cma-frame grid h-full grid-cols-[var(--rail-width)_1fr] grid-rows-[var(--spacing-topbar)_minmax(0,1fr)] overflow-hidden"
      aria-busy="true"
    >
      <header className="col-span-2 flex items-center justify-between border-b border-p4a-border bg-white px-6">
        <div className="flex items-center gap-4">{bar("w-36", "h-7")}{bar("w-24")}</div>
        <div className="flex items-center gap-5">{bar("w-40")}{bar("w-20", "h-8")}</div>
      </header>
      <nav aria-hidden="true" className="flex min-h-0 flex-col gap-2 overflow-hidden border-r border-p4a-border bg-p4a-bgblue px-4 py-6">
        {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
          <div key={i} className="flex h-10 items-center gap-3 px-3">{bar("w-5", "h-5")}{bar(i % 3 === 0 ? "w-24" : "w-32")}</div>
        ))}
      </nav>
      <main className="min-h-0 overflow-hidden bg-p4a-sand px-10 py-8">
        <div className="max-w-screen-2xl">
          {shape === "liveBoard" ? (
            // the board's own title row (the freshness on it, as LiveBoardLive draws it) and its two-line intro, then the
            // panels at their heights: a title line of 25px, labels of 18px, figures of 31px
            <div className="mb-6 flex items-end justify-between border-b border-p4a-border pb-3">{bar("w-72", "h-8")}{bar("w-80", "h-3")}</div>
          ) : (
            bar("w-72", "h-8")
          )}
          <div className="mt-3 flex flex-col gap-2">{bar("w-96", "h-3")}{shape === "liveBoard" ? bar("w-80", "h-3") : null}</div>
          {shape === "liveBoard" ? (
            <div className="mt-6 flex flex-col gap-6" data-skeleton-shape="liveBoard">
              {[0, 1, 2, 3].map((i) => (
                <section key={i} className="rounded-card border border-p4a-border bg-white p-6">
                  {bar("w-56", "h-6")}
                  <div className="mt-4 grid grid-cols-6 divide-x divide-p4a-border">
                    {[0, 1, 2, 3, 4, 5].map((j) => (
                      <div key={j} className="flex flex-col gap-1 px-4 first:pl-0 last:pr-0">{bar("w-3/4", "h-4")}{bar("w-1/2", "h-8")}</div>
                    ))}
                  </div>
                </section>
              ))}
              <div className="flex flex-col gap-3">{[0, 1, 2, 3].map((i) => <div key={i}>{bar("w-full", "h-8")}</div>)}</div>
            </div>
          ) : (
          <div className="mt-8 grid grid-cols-[1fr_18rem] gap-6">
            <div className="flex flex-col gap-6">
              {[0, 1].map((i) => (
                <section key={i} className="rounded-card border border-p4a-border bg-white p-6">
                  {bar("w-48", "h-5")}
                  <div className="mt-5 flex flex-col gap-3">{bar("w-full", "h-3")}{bar("w-5/6", "h-3")}{bar("w-2/3", "h-3")}</div>
                </section>
              ))}
            </div>
            <div className="flex flex-col gap-6">
              <section className="rounded-card border border-p4a-border bg-white p-6">
                {bar("w-32", "h-5")}
                <div className="mt-5 flex flex-col gap-3">{bar("w-full", "h-3")}{bar("w-3/4", "h-3")}</div>
              </section>
            </div>
          </div>
          )}
        </div>
      </main>
    </div>
  );
}
