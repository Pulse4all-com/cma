/**
 * The route skeleton (night N06, 5 November 2026): what a click shows within 100 ms, before the destination's data
 * is there. The page's frame as Shell draws it (the white top bar, the rail on Background Blue, the Sand content area)
 * with placeholder blocks where the title and the cards go, in the style guide's colours and radii (7.1, 7.3); no
 * spinner. Every route segment's loading.tsx renders it, and the rail's links prefetch it, so the frame is on screen
 * while the page's reads run. Static: it reads no cookie and no data, so the rail shows expanded; the page then
 * replaces it with the frame in the person's state.
 */
export function RouteSkeleton() {
  const bar = (w: string, h = "h-4") => <div className={`${h} ${w} animate-pulse rounded-input bg-p4a-border`} aria-hidden="true" />;
  return (
    <div
      data-route-skeleton
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
          {bar("w-72", "h-8")}
          <div className="mt-3">{bar("w-96", "h-3")}</div>
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
        </div>
      </main>
    </div>
  );
}
