/**
 * The link to a record in its own system (a deal, ticket, call or task), opened in a new window, or a Muted dash
 * when the connection has no link template. A plain component with no server-only imports, so the server's report
 * parts and the client-drawn rows of Follow-up (FollowUpRows) share it.
 */
export function RecordLink({ url, label }: { url: string | null; label: string }) {
  if (!url) return <span className="text-p4a-muted">–</span>;
  return (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={label}
      title={label}
      className="inline-flex h-8 w-8 items-center justify-center rounded-button text-p4a-deepblue hover:bg-p4a-bgblue"
    >
      <svg aria-hidden="true" viewBox="0 0 20 20" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="1.75" strokeLinecap="round" strokeLinejoin="round">
        <path d="M11 3h6v6" />
        <path d="M17 3l-8 8" />
        <path d="M15 12v4a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h4" />
      </svg>
    </a>
  );
}
