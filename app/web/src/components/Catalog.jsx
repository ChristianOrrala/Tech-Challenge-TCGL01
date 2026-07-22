import { useEffect, useRef, useState } from 'react'
import Panel, { Skeleton, Unavailable } from './Panel.jsx'
import { fetchCatalog } from '../api.js'
import { formatFixed1, formatUtcDay, formatUtcStamp, magSeverityClass } from '../format.js'

// The catalog is the browse layer under the three at-a-glance panels. It
// owns its fetching and is deliberately NOT wired into App's 60 s
// refreshAll poller: a paged browse surface must never have its page
// yanked out from under the reader by a background poll. Data moves only
// when the reader moves a control, sorts, or pages.

const MIN_MAG_OPTIONS = ['2.0', '4.0', '5.0', '6.0']
const LIMIT_OPTIONS = [25, 50, 100]
const DEFAULT_QUERY = { sort: 'time', order: 'desc', minMag: '', from: '', to: '', limit: 25 }
// Page 1 is "no cursor". trail keeps the cursor of every page before the
// current one: a keyset API only pages forward, so the honest way back is
// replaying the cursor that produced the previous page - there is no
// offset to jump to.
const FIRST_PAGE = { cursor: null, trail: [] }

const SORT_LABELS = { time: 'Time (UTC)', magnitude: 'Mag' }

// The filter/sort slice lives in the URL (?min_mag=4.0&from=...&sort=...)
// so a built-up view survives refresh and can be pasted into an incident
// doc. Values hydrate through the same whitelists the controls offer, so a
// mangled link degrades to defaults instead of an invalid request. The
// cursor is deliberately not encoded: cursors are minted per listing and go
// stale, so a deep link honestly lands on page 1 of its slice.
function queryFromUrl(search) {
  const params = new URLSearchParams(search)
  const pick = (key, allowed) => (allowed.includes(params.get(key)) ? params.get(key) : null)
  const day = (key) => (/^\d{4}-\d{2}-\d{2}$/.test(params.get(key) ?? '') ? params.get(key) : null)
  const limit = Number(params.get('limit'))
  return {
    sort: pick('sort', ['time', 'magnitude']) ?? DEFAULT_QUERY.sort,
    order: pick('order', ['desc', 'asc']) ?? DEFAULT_QUERY.order,
    minMag: pick('min_mag', MIN_MAG_OPTIONS) ?? DEFAULT_QUERY.minMag,
    from: day('from') ?? DEFAULT_QUERY.from,
    to: day('to') ?? DEFAULT_QUERY.to,
    limit: LIMIT_OPTIONS.includes(limit) ? limit : DEFAULT_QUERY.limit,
  }
}

// Only non-defaults travel, so the address bar stays clean until the reader
// narrows something. replaceState, not pushState: Back should leave the
// page, not unwind every filter twitch.
function syncUrl(query) {
  const params = new URLSearchParams()
  if (query.sort !== DEFAULT_QUERY.sort) params.set('sort', query.sort)
  if (query.order !== DEFAULT_QUERY.order) params.set('order', query.order)
  if (query.minMag) params.set('min_mag', query.minMag)
  if (query.from) params.set('from', query.from)
  if (query.to) params.set('to', query.to)
  if (query.limit !== DEFAULT_QUERY.limit) params.set('limit', String(query.limit))
  const search = params.toString()
  window.history.replaceState(null, '', `${window.location.pathname}${search ? `?${search}` : ''}`)
}

// A real button inside the th: keyboard activation and focus-visible come
// native. aria-sort lives on the th and only on the active column; the
// arrow is derived from the same state, so the two cannot drift. The idle
// updown glyph is what separates a sortable column from a plain header
// before any interaction.
function SortHeader({ column, query, onSort, className }) {
  const active = query.sort === column
  const ariaSort = active ? (query.order === 'desc' ? 'descending' : 'ascending') : undefined
  return (
    <th scope="col" className={className} aria-sort={ariaSort}>
      <button type="button" className="sort-btn" onClick={() => onSort(column)}>
        {SORT_LABELS[column]}
        <span className={active ? 'sort-arrow' : 'sort-arrow sort-arrow-idle'} aria-hidden="true">
          {active ? (query.order === 'desc' ? '↓' : '↑') : '↕'}
        </span>
      </button>
    </th>
  )
}

export default function Catalog() {
  const [query, setQuery] = useState(() => queryFromUrl(window.location.search))
  const [page, setPage] = useState(FIRST_PAGE)
  const [attempt, setAttempt] = useState(0)
  const [{ data, error, fetchedAt }, setPanel] = useState({ data: null, error: null, fetchedAt: null })
  const [busy, setBusy] = useState(false)
  // One line of explanation for when the 422 recovery silently relocates
  // the reader; cleared by their next deliberate move.
  const [notice, setNotice] = useState(null)
  // Monotonic fetch id: only the newest in-flight request may land, so a
  // slow page 2 response can never overwrite the page the reader has
  // since asked for.
  const seqRef = useRef(0)

  // Both dates set and inverted is a malformed question, not an empty
  // result. Plain string compare is exact for YYYY-MM-DD values.
  const invalidRange = Boolean(query.from && query.to && query.from > query.to)

  useEffect(() => {
    if (query.from && query.to && query.from > query.to) {
      // Never ask the API a question no date can satisfy; bump the seq so
      // a response already in flight cannot land under the message.
      seqRef.current += 1
      setBusy(false)
      return
    }
    const seq = ++seqRef.current
    setBusy(true)
    fetchCatalog({ ...query, cursor: page.cursor })
      .then((result) => {
        if (seqRef.current !== seq) return
        setPanel({ data: result, error: null, fetchedAt: Date.now() })
      })
      .catch((err) => {
        if (seqRef.current !== seq) return
        // A 422 while holding a cursor means the cursor went stale (a
        // redeploy can change how cursors are minted). Reset to page 1 -
        // exactly once: the retried request carries no cursor, so a second
        // 422 lands as a real error instead of looping.
        if (err.status === 422 && page.cursor !== null) {
          setNotice('Listing changed upstream - back to page 1')
          setPage(FIRST_PAGE)
          return
        }
        setPanel((prev) => ({ ...prev, error: err }))
      })
      .finally(() => {
        if (seqRef.current === seq) setBusy(false)
      })
  }, [query, page, attempt])

  useEffect(() => {
    syncUrl(query)
  }, [query])

  // Every control or sort change restarts from page 1 and drops the trail:
  // cursors are minted for one sort/order/filter listing server-side and
  // must never be reused across a change.
  const changeQuery = (patch) => {
    setNotice(null)
    setQuery((prev) => ({ ...prev, ...patch }))
    setPage(FIRST_PAGE)
  }

  // First click on a column sorts it desc, second click flips to asc.
  const changeSort = (column) => {
    setNotice(null)
    setQuery((prev) =>
      prev.sort === column
        ? { ...prev, order: prev.order === 'desc' ? 'asc' : 'desc' }
        : { ...prev, sort: column, order: 'desc' },
    )
    setPage(FIRST_PAGE)
  }

  const retry = () => {
    setNotice(null)
    setAttempt((n) => n + 1)
  }

  // Clicks during an in-flight page fetch are dropped rather than the
  // buttons disabled: disabling under the pointer would eject keyboard
  // focus mid-flow, and acting on not-yet-replaced data would corrupt the
  // trail. Structural disabling below (page 1 / last page) still applies.
  //
  // Next also freezes while an error is showing: after a failed swap the
  // rows (and their next_cursor) belong to an earlier request, so pushing
  // that cursor would extend the trail with a page the reader never
  // reached. The trail itself is always this listing's own (every change
  // clears it), which is why Prev stays safe during the same outage.
  const goNext = () => {
    setNotice(null)
    if (busy || error || !data?.next_cursor) return
    const next = data.next_cursor
    setPage((prev) => ({ cursor: next, trail: [...prev.trail, prev.cursor] }))
  }

  const goPrev = () => {
    setNotice(null)
    if (busy) return
    setPage((prev) => {
      if (prev.trail.length === 0) return prev
      return { cursor: prev.trail[prev.trail.length - 1], trail: prev.trail.slice(0, -1) }
    })
  }

  const items = data?.items ?? []
  const pageNumber = page.trail.length + 1

  // Coverage is the honest boundary of what the catalog holds (ADR 014);
  // before the first response, or on an empty catalog, there are no dates
  // to claim, so the sub falls back to naming the surface.
  const coverage = data?.coverage
  // "M 4.0+" (not ">= 4.0") so the coverage line cannot be misread as a
  // typo of the recent panel's "M > 4.0" - the two filters really differ.
  const coverageParts = [
    coverage?.all_since ? `all magnitudes since ${formatUtcDay(coverage.all_since)}` : null,
    coverage?.m4_since ? `M 4.0+ since ${formatUtcDay(coverage.m4_since)}` : null,
  ].filter(Boolean)
  const sub = coverageParts.length > 0 ? coverageParts.join(' · ') : 'full recorded history'

  return (
    <Panel
      id="catalog"
      title="Earthquake catalog"
      sub={sub}
      error={error}
      hasData={Boolean(data)}
      fetchedAt={fetchedAt}
    >
      <div className="catalog-controls">
        <label className="control">
          <span className="control-label">Min mag</span>
          <select
            className="inline-select"
            value={query.minMag}
            onChange={(event) => changeQuery({ minMag: event.target.value })}
          >
            <option value="">Any</option>
            {MIN_MAG_OPTIONS.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </label>
        {/* From+To travel as one flex item so a wrapping toolbar can never
            split the range across rows. min/max cross-constrain the native
            pickers; typed input can still invert, which the fetch guard
            answers honestly instead of querying. */}
        <div className="control-range">
          <label className="control">
            <span className="control-label">From</span>
            <input
              type="date"
              className="date-input"
              title="UTC day"
              max={query.to || undefined}
              value={query.from}
              onChange={(event) => changeQuery({ from: event.target.value })}
            />
          </label>
          <label className="control">
            <span className="control-label">To</span>
            <input
              type="date"
              className="date-input"
              title="UTC day"
              min={query.from || undefined}
              value={query.to}
              onChange={(event) => changeQuery({ to: event.target.value })}
            />
          </label>
        </div>
        <label className="control">
          <span className="control-label">Rows</span>
          <select
            className="inline-select"
            value={query.limit}
            onChange={(event) => changeQuery({ limit: Number(event.target.value) })}
          >
            {LIMIT_OPTIONS.map((n) => (
              <option key={n} value={n}>
                {n}
              </option>
            ))}
          </select>
        </label>
      </div>
      {invalidRange ? (
        <p className="empty-state" role="status">
          From is after To - no dates can match. Adjust one of the dates.
        </p>
      ) : !data && !error ? (
        <Skeleton label="Loading earthquake catalog" rows={8} />
      ) : !data ? (
        <>
          <Unavailable what="the earthquake catalog" hint="use Retry or adjust a filter" />
          <button type="button" className="refresh-btn catalog-retry" onClick={retry}>
            Retry
          </button>
        </>
      ) : items.length === 0 ? (
        <p className="empty-state">No earthquakes match these filters - widen the dates or lower Min mag</p>
      ) : (
        <>
          <div
            className="table-scroll catalog-scroll"
            tabIndex={0}
            role="region"
            aria-label="Earthquake catalog, scrollable table"
            aria-busy={busy}
          >
            <table className="data-table">
              <caption className="sr-only">
                Historical earthquake catalog, one row per recorded event, ordered and filtered by the
                controls above
              </caption>
              <thead>
                <tr>
                  <SortHeader column="time" query={query} onSort={changeSort} />
                  <SortHeader column="magnitude" query={query} onSort={changeSort} className="num" />
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
                      {formatUtcStamp(quake.time)}
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
          {query.sort === 'magnitude' && (
            <p className="table-footnote">
              Events without a measured magnitude are not listed when sorting by magnitude.
            </p>
          )}
          {/* aria-disabled instead of disabled: a pager button that turns
              off under the pointer (reaching page 1 or the last page) must
              not eject keyboard focus to the document. The handlers already
              drop dead clicks. The sr-only suffix makes the status region
              also announce sort changes, which swap rows silently otherwise. */}
          <div className="catalog-pager">
            <button type="button" className="refresh-btn" onClick={goPrev} aria-disabled={pageNumber === 1}>
              Previous
            </button>
            <span className="pager-page" role="status">
              {`Page ${pageNumber}`}
              <span className="sr-only">
                {`, sorted by ${query.sort} ${query.order === 'desc' ? 'descending' : 'ascending'}`}
              </span>
            </span>
            <button
              type="button"
              className="refresh-btn"
              onClick={goNext}
              aria-disabled={Boolean(error) || !data.next_cursor}
            >
              Next
            </button>
            {error ? (
              <button type="button" className="refresh-btn" onClick={retry}>
                Retry
              </button>
            ) : null}
            {notice ? (
              <span className="pager-note" role="status">
                {notice}
              </span>
            ) : null}
          </div>
        </>
      )}
    </Panel>
  )
}
