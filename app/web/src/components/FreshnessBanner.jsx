// The graceful-degradation surface: amber whenever the freshness check
// itself failed or the API reports stale data, green only once the check
// has succeeded and the feed is current.
function formatLocal(iso) {
  if (!iso) return 'unknown'
  return new Date(iso).toLocaleString()
}

function minutesAgo(ageSeconds) {
  return Math.round(ageSeconds / 60)
}

export default function FreshnessBanner({ data, error }) {
  if (!data && !error) {
    return (
      <div className="banner banner-loading" role="status">
        Checking data freshness...
      </div>
    )
  }

  const degraded = Boolean(error) || data?.stale === true

  if (degraded) {
    return (
      <div className="banner banner-amber" role="status">
        Serving cached data - source feed unreachable or stale. Last update:{' '}
        {formatLocal(data?.last_ingest)}
      </div>
    )
  }

  return (
    <div className="banner banner-green" role="status">
      Data as of {formatLocal(data.last_ingest)} ({minutesAgo(data.age_seconds)}m ago)
    </div>
  )
}
