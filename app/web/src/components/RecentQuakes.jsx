function formatTimeUtc(iso) {
  if (!iso) return '-'
  return `${new Date(iso).toISOString().slice(0, 19).replace('T', ' ')} UTC`
}

function formatNumber(value) {
  return typeof value === 'number' ? value.toFixed(1) : '-'
}

export default function RecentQuakes({ data, error }) {
  const items = data?.items ?? []

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Recent quakes</h2>
        {error && <span className="chip">unavailable</span>}
      </div>
      {items.length === 0 ? (
        <p className="empty-state">No quakes above magnitude 4.0 in the last 24 hours</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th>Time UTC</th>
              <th>Mag</th>
              <th>Place</th>
              <th>Depth km</th>
            </tr>
          </thead>
          <tbody>
            {items.map((quake) => (
              <tr key={quake.id}>
                <td>{formatTimeUtc(quake.time)}</td>
                <td>{formatNumber(quake.magnitude)}</td>
                <td>{quake.place ?? '-'}</td>
                <td>{formatNumber(quake.depth_km)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}
