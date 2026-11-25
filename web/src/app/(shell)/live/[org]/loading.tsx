import { RouteSkeleton } from "@/components/RouteSkeleton";

/**
 * The route's loading boundary (night N06; restored on the per-organisation board, Martin, 5 November 2026): the page's
 * frame with placeholder blocks, shown on a click within 100 ms. It sends 200 before the page decides, so an unknown or
 * unflagged key renders the not-found page with status 200 (a soft 404, accepted on Live to keep the skeleton). Since the
 * Live board's UX pass (10 November 2026) in the board's own shape, so nothing jumps when the board arrives
 */
export default function Loading() {
  return <RouteSkeleton shape="liveBoard" />;
}
