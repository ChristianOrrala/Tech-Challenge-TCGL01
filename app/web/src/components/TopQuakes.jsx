import Panel, { Skeleton, Unavailable } from './Panel.jsx'
import { formatFixed1, formatUtcDay, magSeverityClass } from '../format.js'

// Window options stay within the 30-day backfill so every answer is
// complete; the API itself accepts up to 90 but would answer a longer
// window from partial data.
const DAY_OPTIONS = [7, 14, 30]
const LIMIT_OPTIONS = [5, 10, 25]

export default function TopQuakes({ data, error, fetchedAt, query, onQueryChange }) {
  const items = data?.items ?? []

  // The subtitle IS the historical search: a readable sentence whose two
  // numbers are live controls, so the default view stays the classic
  // "top 5, past 30 days" until the reader asks a different question.
  const search = (
    <span className="top-search">
      {'top '}
      <select
        className="inline-select"
        aria-label="How many quakes to list"
        value={query.limit}
        onChange={(event) => onQueryChange({ ...query, limit: Number(event.target.value) })}
      >
        {LIMIT_OPTIONS.map((n) => (
          <option key={n} value={n}>
            {n}
          </option>
        ))}
      </select>
      {' by magnitude · past '}
      <select
        className="inline-select"
        aria-label="Time window in days"
        value={query.days}
        onChange={(event) => onQueryChange({ ...query, days: Number(event.target.value) })}
      >
        {DAY_OPTIONS.map((n) => (
          <option key={n} value={n}>
            {n}
          </option>
        ))}
      </select>
      {' days'}
    </span>
  )

  return (
    <Panel
      id="top"
      title="Strongest quakes"
      sub={search}
      error={error}
      hasData={Boolean(data)}
      fetchedAt={fetchedAt}
    >
      {!data && !error ? (
        <Skeleton label="Loading strongest quakes" rows={5} />
      ) : !data ? (
        <Unavailable what="strongest quakes" />
      ) : items.length === 0 ? (
        <p className="empty-state">{`No quakes recorded in the past ${query.days} days`}</p>
      ) : (
        <ol className="top-quakes">
          {items.map((quake) => (
            <li key={quake.id}>
              <span className={`quake-mag ${magSeverityClass(quake.magnitude)}`.trim()}>
                M {formatFixed1(quake.magnitude)}
              </span>
              <span className="quake-detail">
                <span className="quake-place">{quake.place ?? 'Unknown location'}</span>
                <span className="quake-meta">
                  {formatUtcDay(quake.time)}
                  {typeof quake.depth_km === 'number' ? ` · ${formatFixed1(quake.depth_km)} km deep` : ''}
                </span>
              </span>
            </li>
          ))}
        </ol>
      )}
    </Panel>
  )
}
