import { useEffect, useState } from 'react'
import { formatAge, formatUtcFull } from '../format.js'

const TICK_MS = 30_000

// Re-render on a slow tick so the displayed age keeps moving between polls;
// a "2m ago" that never changes reads as a frozen page.
function useNow(intervalMs) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

// The graceful-degradation surface. Three distinct failure vocabularies:
// - the freshness check itself failed (API/DB unreachable),
// - the API answered but reports a stale ingest pipeline,
// - healthy. Ages inside spans marked aria-hidden so the live region only
// re-announces when the ingest timestamp actually changes, not every tick.
export default function FreshnessBanner({ data, error, fetchedAt }) {
  const now = useNow(TICK_MS)

  if (!data && !error) {
    return (
      <div className="banner banner-loading" role="status">
        Checking data freshness...
      </div>
    )
  }

  if (error) {
    return (
      <div className="banner banner-amber" role="status">
        Status check failed - the API is unreachable.
        {data?.last_ingest
          ? ` Panels keep the last data they loaded. Last known ingest: ${formatUtcFull(data.last_ingest)}.`
          : ' Retrying every 60 s.'}
      </div>
    )
  }

  // Server-computed age is authoritative at fetch time; add wall time since.
  const ageSeconds =
    typeof data.age_seconds === 'number'
      ? data.age_seconds + Math.max(0, Math.round((now - (fetchedAt ?? now)) / 1000))
      : null

  if (data.stale || data.last_ingest == null) {
    return (
      <div className="banner banner-amber" role="status">
        {data.last_ingest == null
          ? 'No data ingested yet - the pipeline has not written any events.'
          : `Ingestion stale - no new data since ${formatUtcFull(data.last_ingest)}`}
        {ageSeconds != null && <span aria-hidden="true"> ({formatAge(ageSeconds)})</span>}
      </div>
    )
  }

  return (
    <div className="banner banner-green" role="status">
      Data as of {formatUtcFull(data.last_ingest)}
      {ageSeconds != null && <span aria-hidden="true"> ({formatAge(ageSeconds)})</span>}
    </div>
  )
}
