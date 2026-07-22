import Panel, { Skeleton, Unavailable } from './Panel.jsx'
import { formatFixed1, formatUtcDay, magSeverityClass } from '../format.js'

export default function TopQuakes({ data, error, fetchedAt }) {
  const items = data?.items ?? []

  return (
    <Panel
      id="top"
      title="Strongest quakes"
      sub="top 5 by magnitude · past 30 days"
      error={error}
      hasData={Boolean(data)}
      fetchedAt={fetchedAt}
    >
      {!data && !error ? (
        <Skeleton label="Loading strongest quakes" rows={5} />
      ) : !data ? (
        <Unavailable what="strongest quakes" />
      ) : items.length === 0 ? (
        <p className="empty-state">No quake data available</p>
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
