import { useCallback, useEffect, useState } from 'react'
import FreshnessBanner from './components/FreshnessBanner.jsx'
import RecentQuakes from './components/RecentQuakes.jsx'
import WeeklyChart from './components/WeeklyChart.jsx'
import TopQuakes from './components/TopQuakes.jsx'
import { fetchFreshness, fetchRecentQuakes, fetchTopQuakes, fetchWeeklyAverages } from './api.js'

const REFRESH_MS = 60_000
const EMPTY_PANEL = { data: null, error: null, fetchedAt: null }

// Runs one endpoint fetch and updates only its own panel state. On failure
// the previous data and its fetch time (if any) are kept alongside the
// error, so a transient blip degrades to "stale" instead of blanking a
// panel that was already showing data.
function refreshPanel(load, setPanel) {
  return load()
    .then((data) => setPanel({ data, error: null, fetchedAt: Date.now() }))
    .catch((error) => setPanel((prev) => ({ ...prev, error })))
}

export default function App() {
  const [recent, setRecent] = useState(EMPTY_PANEL)
  const [weekly, setWeekly] = useState(EMPTY_PANEL)
  const [top, setTop] = useState(EMPTY_PANEL)
  const [freshness, setFreshness] = useState(EMPTY_PANEL)
  const [refreshing, setRefreshing] = useState(false)

  const refreshAll = useCallback(async () => {
    setRefreshing(true)
    try {
      // refreshPanel never rejects (errors land in panel state), but
      // allSettled keeps one panel's surprise from stranding the button.
      await Promise.allSettled([
        refreshPanel(fetchRecentQuakes, setRecent),
        refreshPanel(fetchWeeklyAverages, setWeekly),
        refreshPanel(fetchTopQuakes, setTop),
        refreshPanel(fetchFreshness, setFreshness),
      ])
    } finally {
      setRefreshing(false)
    }
  }, [])

  useEffect(() => {
    refreshAll()
    const id = setInterval(refreshAll, REFRESH_MS)
    return () => clearInterval(id)
  }, [refreshAll])

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-heading">
          <h1>Earthquake Monitor</h1>
          <p className="app-sub">Global seismic activity from the USGS feed · auto-refreshes every 60 s</p>
        </div>
        <button type="button" className="refresh-btn" onClick={refreshAll} disabled={refreshing}>
          {refreshing ? 'Refreshing...' : 'Refresh'}
        </button>
      </header>
      <FreshnessBanner data={freshness.data} error={freshness.error} fetchedAt={freshness.fetchedAt} />
      <main className="panels">
        <RecentQuakes data={recent.data} error={recent.error} fetchedAt={recent.fetchedAt} />
        <WeeklyChart data={weekly.data} error={weekly.error} fetchedAt={weekly.fetchedAt} />
        <TopQuakes data={top.data} error={top.error} fetchedAt={top.fetchedAt} />
      </main>
    </div>
  )
}
