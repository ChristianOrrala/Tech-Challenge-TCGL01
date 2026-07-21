const BASE = '/api'

// Fetches JSON from a same-origin path. Throws on a non-ok response with
// the HTTP status attached, so callers can log or branch on it.
export async function fetchJson(path) {
  const res = await fetch(path)
  if (!res.ok) {
    const error = new Error(`${path} responded with ${res.status}`)
    error.status = res.status
    throw error
  }
  return res.json()
}

export function fetchRecentQuakes() {
  return fetchJson(`${BASE}/quakes/recent`)
}

export function fetchWeeklyAverages() {
  return fetchJson(`${BASE}/quakes/weekly-averages`)
}

export function fetchTopQuakes(days = 30, limit = 5) {
  return fetchJson(`${BASE}/quakes/top?days=${days}&limit=${limit}`)
}

export function fetchFreshness() {
  return fetchJson(`${BASE}/meta/freshness`)
}
