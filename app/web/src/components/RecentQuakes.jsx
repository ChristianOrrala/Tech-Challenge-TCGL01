import Panel, { Skeleton, Unavailable } from './Panel.jsx'
import { formatFixed1, formatUtcShort, magSeverityClass } from '../format.js'

export default function RecentQuakes({ data, error, fetchedAt }) {
  const items = data?.items ?? []
  const count = data?.count ?? items.length
  // Scope mirrors the API's actual filter (magnitude > 4.0, trailing 24 h);
  // the live event count doubles as proof the feed is moving.
  const sub = data
    ? `M > 4.0 · past 24 h · ${count} ${count === 1 ? 'event' : 'events'}`
    : 'M > 4.0 · past 24 h'

  return (
    <Panel
      id="recent"
      title="Recent quakes"
      sub={sub}
      error={error}
      hasData={Boolean(data)}
      fetchedAt={fetchedAt}
    >
      {!data && !error ? (
        <Skeleton label="Loading recent quakes" rows={6} />
      ) : !data ? (
        <Unavailable what="recent quakes" />
      ) : items.length === 0 ? (
        <p className="empty-state">No quakes above magnitude 4.0 in the last 24 hours</p>
      ) : (
        <div className="table-scroll" tabIndex={0} role="region" aria-label="Recent quakes, scrollable table">
          <table className="data-table">
            <caption className="sr-only">
              Earthquakes above magnitude 4.0 in the past 24 hours, most recent first
            </caption>
            <thead>
              <tr>
                <th scope="col">Time (UTC)</th>
                <th scope="col" className="num">
                  Mag
                </th>
                <th scope="col">Place</th>
                <th scope="col" className="num">
                  Depth (km)
                </th>
              </tr>
            </thead>
            <tbody>
              {items.map((quake) => (
                <tr key={quake.id}>
                  <td className="cell-time" title={quake.time ?? undefined}>
                    {formatUtcShort(quake.time)}
                  </td>
                  <td className={`num ${magSeverityClass(quake.magnitude)}`.trim()}>
                    {formatFixed1(quake.magnitude)}
                  </td>
                  <td className="cell-place">{quake.place ?? '-'}</td>
                  <td className="num">{formatFixed1(quake.depth_km)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  )
}
