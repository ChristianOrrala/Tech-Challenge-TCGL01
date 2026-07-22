import { formatUtcClock } from '../format.js'

// Shared panel chrome so all three panels expose the same state vocabulary:
// - loading (Skeleton), before the first response arrives
// - unavailable (Unavailable), fetch failed and there is nothing to show
// - stale, fetch failing but earlier data is still on screen (chip + "as of")
// - empty vs data, decided by each panel's own content.
// The status region is always mounted so chip changes are announced.
export default function Panel({ id, title, sub, error, hasData, fetchedAt, children }) {
  const status = error ? (hasData ? 'stale' : 'unavailable') : null
  const staleNote = status === 'stale' && fetchedAt ? ` · as of ${formatUtcClock(fetchedAt)}` : ''

  return (
    <section className={`panel panel-${id}`} aria-labelledby={`${id}-title`}>
      <header className="panel-header">
        <div className="panel-heading">
          <h2 id={`${id}-title`}>{title}</h2>
          {sub ? (
            <p className="panel-sub">
              {sub}
              {staleNote}
            </p>
          ) : null}
        </div>
        <span className="panel-status" role="status">
          {status ? (
            <>
              <span className={`chip chip-${status}`} aria-hidden="true">
                {status}
              </span>
              <span className="sr-only">
                {`${title}: ${status === 'stale' ? 'showing earlier data, refresh failing' : 'data unavailable'}`}
              </span>
            </>
          ) : null}
        </span>
      </header>
      {children}
    </section>
  )
}

export function Skeleton({ label, rows = 4 }) {
  return (
    <div className="skeleton" role="status">
      <span className="sr-only">{label}</span>
      <div className="skeleton-rows" aria-hidden="true">
        {Array.from({ length: rows }, (_, i) => (
          <span key={i} className="skeleton-row" />
        ))}
      </div>
    </div>
  )
}

export function Unavailable({ what }) {
  return <p className="panel-message">{`Could not load ${what} - retrying every 60 s.`}</p>
}
