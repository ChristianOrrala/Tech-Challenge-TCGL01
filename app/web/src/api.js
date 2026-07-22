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

// GET /api/quakes - the paged historical catalog. Only params the reader
// set travel. The To day expands to its last microsecond because the API's
// end bound is an inclusive instant (occurred_at <= end): a To date means
// the whole day, and a date-only value would stop at that day's midnight.
export function fetchCatalog({ sort, order, minMag, from, to, limit, cursor }) {
  const params = new URLSearchParams({ sort, order, limit: String(limit) })
  if (minMag) params.set('min_mag', minMag)
  if (from) params.set('start', from)
  if (to) params.set('end', `${to}T23:59:59.999999`)
  if (cursor) params.set('cursor', cursor)
  return fetchJson(`${BASE}/quakes?${params}`)
}

export function fetchFreshness() {
  return fetchJson(`${BASE}/meta/freshness`)
}
