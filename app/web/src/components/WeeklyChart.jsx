import { useEffect, useRef, useState } from 'react'
import Panel, { Skeleton, Unavailable } from './Panel.jsx'

const HEIGHT = 190
const PAD_TOP = 24
const PAD_BOTTOM = 28
const PAD_X = 4
const BAR_GAP = 8

export default function WeeklyChart({ data, error, fetchedAt }) {
  const daily = data?.daily ?? []
  const average = data?.average_per_day ?? 0

  return (
    <Panel
      id="weekly"
      title="Weekly activity"
      sub="all recorded events · rolling 7 days · UTC day buckets"
      error={error}
      hasData={Boolean(data)}
      fetchedAt={fetchedAt}
    >
      {!data && !error ? (
        <Skeleton label="Loading weekly activity" rows={3} />
      ) : !data ? (
        <Unavailable what="weekly activity" />
      ) : daily.length === 0 ? (
        <p className="empty-state">No weekly data available</p>
      ) : (
        <Bars daily={daily} average={average} />
      )}
    </Panel>
  )
}

// Plain SVG bars, no charting library. The SVG is sized in real pixels from
// the measured container width (not a scaled viewBox) so labels render at a
// legible 11px at every panel width. A rolling 7-day window cut on UTC day
// boundaries yields 8 buckets whose first and last are partial days; those
// are dimmed and footnoted so today's short bar does not read as an outage.
function Bars({ daily, average }) {
  const boxRef = useRef(null)
  const [width, setWidth] = useState(0)

  useEffect(() => {
    const el = boxRef.current
    if (!el) return undefined
    const observer = new ResizeObserver((entries) => {
      setWidth(Math.floor(entries[0].contentRect.width))
    })
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  const hasPartialEdges = daily.length > 7
  const chartWidth = Math.max(0, width - PAD_X * 2)
  const chartHeight = HEIGHT - PAD_TOP - PAD_BOTTOM
  const max = Math.max(1, ...daily.map((day) => day.count))
  const barWidth = daily.length > 0 ? (chartWidth - BAR_GAP * (daily.length - 1)) / daily.length : 0
  const scale = (value) => (value / max) * chartHeight
  const baselineY = HEIGHT - PAD_BOTTOM
  // With partial edge buckets the 7-day average can exceed the tallest bar;
  // clamp the guide line into the plot while the label states the true value.
  const averageY = baselineY - scale(Math.min(average, max))

  const summary =
    `Average ${average.toFixed(1)} quakes per day over the rolling 7-day window. ` +
    `Daily counts: ${daily.map((day) => `${day.date}: ${day.count}`).join(', ')}.`

  return (
    <figure className="chart-box" ref={boxRef}>
      <p className="sr-only">{summary}</p>
      {width > 0 && (
        <svg width={width} height={HEIGHT} className="weekly-chart" aria-hidden="true">
          {daily.map((day, i) => {
            const barHeight = scale(day.count)
            const x = PAD_X + i * (barWidth + BAR_GAP)
            const y = baselineY - barHeight
            const partial = hasPartialEdges && (i === 0 || i === daily.length - 1)
            return (
              <g key={day.date}>
                <rect
                  x={x}
                  y={y}
                  width={Math.max(1, barWidth)}
                  height={barHeight}
                  className={partial ? 'chart-bar chart-bar-partial' : 'chart-bar'}
                >
                  <title>{`${day.count} quakes on ${day.date}${partial ? ' (partial UTC day)' : ''}`}</title>
                </rect>
                <text x={x + barWidth / 2} y={y - 5} className="chart-value" textAnchor="middle">
                  {day.count}
                </text>
                <text x={x + barWidth / 2} y={baselineY + 16} className="chart-label" textAnchor="middle">
                  {day.date.slice(5)}
                </text>
              </g>
            )
          })}
          <line x1={PAD_X} y1={baselineY} x2={width - PAD_X} y2={baselineY} className="chart-baseline" />
          <line x1={PAD_X} y1={averageY} x2={width - PAD_X} y2={averageY} className="chart-average-line" />
          <text x={width - PAD_X} y={averageY - 5} className="chart-average-label" textAnchor="end">
            avg {average.toFixed(1)}/day
          </text>
        </svg>
      )}
      {hasPartialEdges && (
        <figcaption className="chart-note">First and last bars are partial UTC days.</figcaption>
      )}
    </figure>
  )
}
