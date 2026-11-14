import { RouteSkeleton } from "@/components/RouteSkeleton";

/** The route's loading boundary (night N06): the page's frame with placeholder blocks, shown on a click within 100 ms */
export default function Loading() {
  return <RouteSkeleton />;
}
