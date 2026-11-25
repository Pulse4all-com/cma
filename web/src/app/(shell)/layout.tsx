import { ShellFrame } from "@/components/ShellFrame";
import { resolve } from "@/app/access";

/**
 * The persistent frame (night N07, decision D2): every page with the top bar and the rail sits in this route group, and
 * this layout renders the frame once (ShellFrame). A click between two of its pages renders the destination's page
 * alone; the frame, the rail's open group and fold, the hints and the message centre stay. Who is here is resolved as
 * every page resolves it (the same request's identity, read once: lib/auth getAccess is a React cache); without a
 * verified identity the page shows No access on its own, without the frame. No loading boundary sits here: the pages
 * that must answer a real 404 (the journeys, Attempts per agent, Email per agent, Orders per person) keep none above them,
 * and each other route draws its own content skeleton inside main.
 */
export default async function ShellLayout({ children }: LayoutProps<"/">) {
  const r = await resolve();
  if (!r.ok) return children;
  return <ShellFrame copy={r.copy} me={r.me}>{children}</ShellFrame>;
}
