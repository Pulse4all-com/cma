"use client";

/**
 * Assets → Fleet management's map (addition 0009t; brief B37, D1 and D7; brief B38, E1 and E2): the devices In the field by
 * postcode area as markers on the country outlines of Natural Earth (lib/fleet-map-outlines, built once by
 * tools/fleet/build-map.mjs: no tiles, no request leaves the app, so it works behind IAP and the CSP). The tenant's markets
 * are Background Blue with a Light Blue edge, other land neutral grey with a Border edge. Areas whose markers would cover
 * each other on screen form one marker (E1: lib/fleet-management groupOnScreen, recomputed on every zoom; at the closest
 * zoom a group's areas spread apart), sized by its count, with an amber badge for the devices that need attention (Needs
 * attention and No connection) outside the circle, top right, never over the count. Every marker is a button with an
 * aria-label: a group zooms in, an area selects it (the address's area, so the side panel lists its devices). The start
 * view fits the areas with devices In the field under the filters (E2: lib/fleet-management startBoxOf); All markets
 * returns to it, + and − zoom; the zoom animates (unless the person asks for reduced motion). Codes, place names and
 * counts only.
 */
import type { Route } from "next";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useOptimistic, useRef, useState, useTransition } from "react";
import type { FleetArea } from "@/lib/data/types";
import {
  badgeOffsetPx, boxOfPoints, FLEET_ADDRESS, FLEET_MIN_VIEW_KM, fleetHref, fleetPointsOf, groupOnScreen, markerSizePx, spreadClusters, startBoxOf, unionBox,
  viewBetween, viewOfBox, zoomView,
  type FleetTileKey, type FleetView,
} from "@/lib/fleet-management";
import { FLEET_MAP_COUNTRIES } from "@/lib/fleet-map-outlines";

export interface FleetMapLabels {
  mapLabel: string;
  /** The button back to the start view: the Market filter's own words (E2) */
  allMarkets: string;
  zoomIn: string;
  zoomOut: string;
  clusterArea: string;
  clusterGroup: string;
}

const HEIGHT_PX = 520;
const ANIMATION_MS = 350;
/** The view when neither an area nor a market gives one: Europe around the projection's centre */
const EUROPE_BOX: [number, number, number, number] = [-1900, -1500, 1900, 1400];

const fill = (text: string, values: Record<string, string | number>) => text.replace(/\{(\w+)\}/g, (_, k: string) => String(values[k] ?? ""));

export function FleetMap({ areas, tile, markets, selectedAreaId, query, labels, locale }: {
  areas: FleetArea[];
  tile: FleetTileKey | null;
  /** The tenant's markets (codes): filled Background Blue */
  markets: string[];
  selectedAreaId: string | null;
  /** The address the markers keep (the filters and the tile) */
  query: Record<string, string>;
  labels: FleetMapLabels;
  locale: string;
}) {
  const boxRef = useRef<HTMLDivElement>(null);
  const [widthPx, setWidthPx] = useState(960);
  const aspect = HEIGHT_PX / widthPx;
  const points = useMemo(() => fleetPointsOf(areas, tile), [areas, tile]);
  const marketSet = new Set(markets);
  // the start view (E2): the areas with devices In the field under the filters, padded and square; else the tenant's
  // markets' outlines, else the continent
  const homeBox = startBoxOf(areas)
    ?? unionBox(markets.flatMap((m) => (FLEET_MAP_COUNTRIES[m] ? [FLEET_MAP_COUNTRIES[m].box] : []))) ?? EUROPE_BOX;
  // the view: the start view (fitted to the map's shape whatever its width) until the person zooms; then its centre and
  // width, its height following the map's shape, so a resize keeps both
  const [base, setBase] = useState<FleetView | null>(null);
  const view: FleetView = base ? { ...base, h: base.w * aspect } : viewOfBox(homeBox, aspect, 0);
  const setView = (v: FleetView | null) => setBase(v);
  // an area's selection shows at once (its ring, aria-pressed) while the server answers: the 100 ms rule (CLAUDE.md,
  // Performance); the address decides again when the answer is there
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [shownArea, setShownArea] = useOptimistic(selectedAreaId);
  const frame = useRef<number | null>(null);

  // the map's width follows its card; the height stays, so the view keeps its centre and width
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const measure = () => setWidthPx(Math.max(320, Math.round(el.getBoundingClientRect().width)));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  useEffect(() => () => { if (frame.current !== null) cancelAnimationFrame(frame.current); }, []);

  /** Animates to a view; home: back to the start view, fitted again from then on */
  const animateTo = (target: FleetView, home = false) => {
    if (frame.current !== null) cancelAnimationFrame(frame.current);
    const reduced = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduced) { setView(home ? null : target); return; }
    const from = view;
    let start: number | null = null;
    const step = (now: number) => {
      if (start === null) start = now;
      const t = Math.min(1, (now - start) / ANIMATION_MS);
      setView(t >= 1 && home ? null : viewBetween(from, target, t));
      frame.current = t < 1 ? requestAnimationFrame(step) : null;
    };
    frame.current = requestAnimationFrame(step);
  };

  // the markers at the view's scale (E1): grouped where they would cover each other on screen, so they depend on the
  // scale alone; at the closest zoom every area is a marker of its own: a group's areas (two of a city's, a few km apart)
  // are spread around its centre, the largest marker's width apart, so none hides another
  const pxPerKm = widthPx / view.w;
  const grouped = useMemo(() => groupOnScreen(points, pxPerKm), [points, pxPerKm]);
  const closest = view.w <= FLEET_MIN_VIEW_KM * 1.01;
  const largest = Math.max(1, ...(closest ? points : grouped).map((c) => c.count));
  const clusters = closest ? spreadClusters(grouped, (markerSizePx(largest, largest) + 8) / pxPerKm) : grouped;
  const left = view.cx - view.w / 2;
  const top = view.cy - view.h / 2;
  const nf = new Intl.NumberFormat(locale);
  const shownCountries = Object.entries(FLEET_MAP_COUNTRIES).filter(([, c]) =>
    c.box[2] >= left && c.box[0] <= left + view.w && c.box[3] >= top && c.box[1] <= top + view.h);

  return (
    <div className={`relative ${pending ? "cursor-progress [&_[data-testid=fleet-area]]:opacity-80" : ""}`} data-testid="fleet-map" aria-busy={pending || undefined}>
      <div ref={boxRef} className="relative w-full overflow-hidden rounded-input border border-p4a-border bg-white" style={{ height: HEIGHT_PX }}
        role="group" aria-label={labels.mapLabel}>
        <svg viewBox={`${left} ${top} ${view.w} ${view.h}`} width="100%" height={HEIGHT_PX} preserveAspectRatio="none" aria-hidden="true" focusable="false">
          {shownCountries.map(([code, c]) => (
            <path key={code} d={c.d} vectorEffect="non-scaling-stroke" strokeWidth={1} strokeLinejoin="round"
              className={marketSet.has(code) ? "fill-p4a-bgblue stroke-p4a-lightblue" : "fill-p4a-neutral-surface stroke-p4a-border"} />
          ))}
        </svg>
        {clusters.map((c) => {
          const px = ((c.x - left) / view.w) * 100;
          const py = ((c.y - top) / view.h) * 100;
          if (px < -5 || px > 105 || py < -5 || py > 105) return null;
          const size = markerSizePx(c.count, largest);
          const single = c.members.length === 1 ? c.members[0] ?? null : null;
          const lead = [...c.members].sort((a, b) => b.count - a.count)[0];
          const label = single
            ? fill(labels.clusterArea, { code: single.areaCode, area: single.label, n: nf.format(c.count), k: nf.format(c.attention) })
            : fill(labels.clusterGroup, { areas: c.members.length, area: lead?.label ?? "", n: nf.format(c.count), k: nf.format(c.attention) });
          const selected = single !== null && single.areaId === shownArea;
          return (
            <button key={c.key} type="button" aria-label={label} title={label} aria-pressed={single ? selected : undefined}
              data-testid={single ? "fleet-area" : "fleet-group"} data-area={single?.areaId}
              className={`absolute flex -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-p4a-deepblue font-semibold text-white tabular text-small focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2 ${selected ? "z-10 ring-4 ring-p4a-inkt" : "border-2 border-white"}`}
              style={{ left: `${px}%`, top: `${py}%`, width: size, height: size }}
              onClick={() => {
                if (single) {
                  const href = fleetHref({ ...query, [FLEET_ADDRESS.area]: single.areaId }) as Route;
                  startTransition(() => { setShownArea(single.areaId); router.push(href, { scroll: false }); });
                  return;
                }
                const box = boxOfPoints(c.members) ?? [c.x, c.y, c.x, c.y];
                const target = viewOfBox(box, aspect, 0.35);
                animateTo(target.w < view.w / 1.5 ? target : zoomView({ ...view, cx: c.x, cy: c.y }, 2));
              }}>
              <span className="inline-block leading-none" data-testid="fleet-count">{nf.format(c.count)}</span>
              {c.attention > 0 ? (
                // outside the circle, top right: its centre on the circle's edge at 45° (E1), so it never covers the count
                <span data-testid="fleet-badge" aria-hidden="true"
                  className="absolute flex h-4 min-w-5 -translate-x-1/2 -translate-y-1/2 items-center justify-center whitespace-nowrap rounded-full bg-p4a-warning px-1 text-caption font-semibold leading-4 text-p4a-inkt"
                  style={{ left: `calc(50% + ${badgeOffsetPx(size).toFixed(2)}px)`, top: `calc(50% - ${badgeOffsetPx(size).toFixed(2)}px)` }}>
                  {nf.format(c.attention)}
                </span>
              ) : null}
            </button>
          );
        })}
        <div className="absolute left-3 top-3 flex gap-2">
          <button type="button" data-testid="fleet-all-markets" onClick={() => animateTo(viewOfBox(homeBox, aspect, 0), true)}
            className="h-8 rounded-button border border-p4a-deepblue bg-white px-3 text-small font-semibold text-p4a-deepblue focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2">
            {labels.allMarkets}
          </button>
          <button type="button" data-testid="fleet-zoom-in" aria-label={labels.zoomIn} title={labels.zoomIn} onClick={() => animateTo(zoomView(view, 2))}
            className="h-8 w-8 rounded-button border border-p4a-deepblue bg-white text-panel font-semibold leading-none text-p4a-deepblue focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2">
            +
          </button>
          <button type="button" data-testid="fleet-zoom-out" aria-label={labels.zoomOut} title={labels.zoomOut} onClick={() => animateTo(zoomView(view, 0.5))}
            className="h-8 w-8 rounded-button border border-p4a-deepblue bg-white text-panel font-semibold leading-none text-p4a-deepblue focus:outline-none focus-visible:ring-2 focus-visible:ring-p4a-lightblue focus-visible:ring-offset-2">
            −
          </button>
        </div>
      </div>
    </div>
  );
}
