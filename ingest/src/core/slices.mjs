/**
 * The final step of a full read in slices (addition 0008zk, the Airtable adapter's devices; addition 0008zl, the Juo
 * adapter's subscriptions): the run's source ids sorted by their UTF-8 bytes (the database's collation "C") and cut into
 * slices of one size, each with its range: from (its first id; none for the first slice) and before (the next slice's
 * first id; none for the last). Together the slices cover every id once, so every row the run did not read is marked
 * missing in exactly one of them, and each call's work is bounded by its slice, not by the source's size. Pure.
 */

/** Text sorted by its UTF-8 bytes: the database's collation "C", the order of the final step's slices */
export const byBytes = (a, b) => Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));

/** The slices of a run's ids: [{ ids, from, before }], in byte order. */
export function slicesOf(sourceIds, size) {
  const ids = [...sourceIds].sort(byBytes);
  const slices = [];
  for (let i = 0; i < ids.length; i += size) {
    slices.push({ ids: ids.slice(i, i + size), from: i === 0 ? null : ids[i], before: i + size < ids.length ? ids[i + size] : null });
  }
  return slices;
}
