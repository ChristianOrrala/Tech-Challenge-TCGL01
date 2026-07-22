// Shared formatting - every timestamp the UI renders goes through here so
// the whole page speaks one vocabulary: UTC, ISO-ordered, explicitly labeled.

function parse(iso) {
  if (!iso) return null
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? null : date
}

// "2026-07-22 02:29 UTC" - banner and anywhere a full instant is stated.
export function formatUtcFull(iso) {
  const date = parse(iso)
  return date ? `${date.toISOString().slice(0, 16).replace('T', ' ')} UTC` : 'unknown'
}

// "07-22 02:03" - table rows, where the UTC label lives in the column header.
export function formatUtcShort(iso) {
  const date = parse(iso)
  return date ? date.toISOString().slice(5, 16).replace('T', ' ') : '-'
}

// "2026-07-16" - date-only surfaces (top quakes).
export function formatUtcDay(iso) {
  const date = parse(iso)
  return date ? date.toISOString().slice(0, 10) : '-'
}

// "02:03 UTC" from an epoch-ms client timestamp (per-panel stale notes).
export function formatUtcClock(epochMs) {
  return `${new Date(epochMs).toISOString().slice(11, 16)} UTC`
}

export function formatAge(seconds) {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return 'age unknown'
  const s = Math.max(0, Math.round(seconds))
  if (s < 60) return `${s}s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  return `${h}h ${m % 60}m ago`
}

export function formatFixed1(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value.toFixed(1) : '-'
}

// Severity emphasis is redundant with the printed number (never the only
// carrier of meaning); thresholds follow the usual reading of M6+ as strong
// and M7+ as major.
export function magSeverityClass(magnitude) {
  if (typeof magnitude !== 'number') return ''
  if (magnitude >= 7) return 'mag-major'
  if (magnitude >= 6) return 'mag-strong'
  return ''
}
