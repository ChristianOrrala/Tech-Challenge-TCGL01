import { useCallback, useEffect, useRef, useState } from 'react'
import Catalog from './components/Catalog.jsx'
import FreshnessBanner from './components/FreshnessBanner.jsx'
import RecentQuakes from './components/RecentQuakes.jsx'
import WeeklyChart from './components/WeeklyChart.jsx'
import TopQuakes from './components/TopQuakes.jsx'
import { fetchFreshness, fetchRecentQuakes, fetchTopQuakes, fetchWeeklyAverages } from './api.js'

const REFRESH_MS = 60_000
const EMPTY_PANEL = { data: null, error: null, fetchedAt: null }
// Defaults mirror the API's own (top 5, past 30 days); the panel's search
// controls can narrow the window or widen the list within what the 30-day
// backfill can honestly answer.
const TOP_DEFAULT = { days: 30, limit: 5 }

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
  const [topQuery, setTopQuery] = useState(TOP_DEFAULT)
  // The query lives in a ref as well as state: the ref keeps refreshAll
  // stable (so a search does not reset the 60 s interval), the state drives
  // the controls.
  const topQueryRef = useRef(TOP_DEFAULT)

  const refreshAll = useCallback(async () => {
    setRefreshing(true)
    try {
      const { days, limit } = topQueryRef.current
      // refreshPanel never rejects (errors land in panel state), but
      // allSettled keeps one panel's surprise from stranding the button.
      await Promise.allSettled([
        refreshPanel(fetchRecentQuakes, setRecent),
        refreshPanel(fetchWeeklyAverages, setWeekly),
        refreshPanel(() => fetchTopQuakes(days, limit), setTop),
        refreshPanel(fetchFreshness, setFreshness),
      ])
    } finally {
      setRefreshing(false)
    }
  }, [])

  // A search refetches only its own panel, keeping earlier rows on screen
  // during the swap (same degrade-not-blank behavior as the poller).
  const searchTop = useCallback((next) => {
    topQueryRef.current = next
    setTopQuery(next)
    refreshPanel(() => fetchTopQuakes(next.days, next.limit), setTop)
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
      <main>
        <div className="panels">
          <RecentQuakes data={recent.data} error={recent.error} fetchedAt={recent.fetchedAt} />
          <WeeklyChart data={weekly.data} error={weekly.error} fetchedAt={weekly.fetchedAt} />
          <TopQuakes
            data={top.data}
            error={top.error}
            fetchedAt={top.fetchedAt}
            query={topQuery}
            onQueryChange={searchTop}
          />
        </div>
        {/* Browse layer: full width below the grid, fetches on its own -
            deliberately outside the 60 s poller (see Catalog.jsx). */}
        <Catalog />
      </main>
    </div>
  )
}
