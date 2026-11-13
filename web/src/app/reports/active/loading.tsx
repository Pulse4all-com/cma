import { RouteSkeleton } from "@/components/RouteSkeleton";

/**
 * The route's loading boundary (night N06): the page's frame with placeholder blocks in the page's own outline (six
 * tiles, six slots, the wide chart, two halves, the tables), shown on a click within 100 ms
 */
export default function Loading() {
  return <RouteSkeleton shape="active" />;
}
