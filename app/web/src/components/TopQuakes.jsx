function formatDate(iso) {
  if (!iso) return '-'
  return new Date(iso).toISOString().slice(0, 10)
}

export default function TopQuakes({ data, error }) {
  const items = data?.items ?? []

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Top quakes (30 days)</h2>
        {error && <span className="chip">unavailable</span>}
      </div>
      {items.length === 0 ? (
        <p className="empty-state">No quake data available</p>
      ) : (
        <ol className="top-quakes">
          {items.map((quake) => (
            <li key={quake.id}>
              <strong>{typeof quake.magnitude === 'number' ? quake.magnitude.toFixed(1) : '-'}</strong>{' '}
              {quake.place ?? 'Unknown location'}
              <span className="quake-date">{formatDate(quake.time)}</span>
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}
