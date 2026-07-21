import { useEffect, useState } from 'react'
import FreshnessBanner from './components/FreshnessBanner.jsx'
import RecentQuakes from './components/RecentQuakes.jsx'
import WeeklyChart from './components/WeeklyChart.jsx'
import TopQuakes from './components/TopQuakes.jsx'
import { fetchFreshness, fetchRecentQuakes, fetchTopQuakes, fetchWeeklyAverages } from './api.js'

const REFRESH_MS = 60_000
const EMPTY_PANEL = { data: null, error: null }

// Runs one endpoint fetch and updates only its own panel state. On failure
// the previous data (if any) is kept alongside the error, so a transient
// blip degrades gracefully instead of blanking a panel that was already
// showing data.
function refreshPanel(load, setPanel) {
  load()
    .then((data) => setPanel({ data, error: null }))
    .catch((error) => setPanel((prev) => ({ data: prev.data, error })))
}

export default function App() {
  const [recent, setRecent] = useState(EMPTY_PANEL)
  const [weekly, setWeekly] = useState(EMPTY_PANEL)
  const [top, setTop] = useState(EMPTY_PANEL)
  const [freshness, setFreshness] = useState(EMPTY_PANEL)

  useEffect(() => {
    function refreshAll() {
      refreshPanel(fetchRecentQuakes, setRecent)
      refreshPanel(fetchWeeklyAverages, setWeekly)
      refreshPanel(fetchTopQuakes, setTop)
      refreshPanel(fetchFreshness, setFreshness)
    }

    refreshAll()
    const id = setInterval(refreshAll, REFRESH_MS)
    return () => clearInterval(id)
  }, [])

  return (
    <div className="app">
      <header className="app-header">
        <h1>Earthquake Monitor</h1>
      </header>
      <FreshnessBanner data={freshness.data} error={freshness.error} />
      <main className="panels">
        <RecentQuakes data={recent.data} error={recent.error} />
        <WeeklyChart data={weekly.data} error={weekly.error} />
        <TopQuakes data={top.data} error={top.error} />
      </main>
    </div>
  )
}
