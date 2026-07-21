const WIDTH = 480
const HEIGHT = 200
const PADDING = 32
const BAR_GAP = 8

export default function WeeklyChart({ data, error }) {
  const daily = data?.daily ?? []
  const average = data?.average_per_day ?? 0

  return (
    <section className="panel">
      <div className="panel-header">
        <h2>Weekly activity</h2>
        {error && <span className="chip">unavailable</span>}
      </div>
      {daily.length === 0 ? (
        <p className="empty-state">No weekly data available</p>
      ) : (
        <Bars daily={daily} average={average} />
      )}
    </section>
  )
}

// Plain SVG bars, no charting library: one bar per day, y-scaled to the
// tallest day, plus a dashed line marking the 7-day average.
function Bars({ daily, average }) {
  const chartWidth = WIDTH - PADDING * 2
  const chartHeight = HEIGHT - PADDING * 2
  const max = Math.max(1, ...daily.map((day) => day.count))
  const barWidth = (chartWidth - BAR_GAP * (daily.length - 1)) / daily.length
  const scale = (value) => (value / max) * chartHeight
  const averageY = PADDING + chartHeight - scale(average)

  return (
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} className="weekly-chart" role="img" aria-label="Quake counts for the last 7 days">
      {daily.map((day, i) => {
        const barHeight = scale(day.count)
        const x = PADDING + i * (barWidth + BAR_GAP)
        const y = PADDING + chartHeight - barHeight
        return (
          <g key={day.date}>
            <rect x={x} y={y} width={barWidth} height={barHeight} className="chart-bar" />
            <text x={x + barWidth / 2} y={y - 4} className="chart-value" textAnchor="middle">
              {day.count}
            </text>
            <text x={x + barWidth / 2} y={HEIGHT - PADDING + 14} className="chart-label" textAnchor="middle">
              {day.date.slice(5)}
            </text>
          </g>
        )
      })}
      <line x1={PADDING} y1={averageY} x2={WIDTH - PADDING} y2={averageY} className="chart-average-line" />
      <text x={WIDTH - PADDING} y={averageY - 4} className="chart-average-label" textAnchor="end">
        avg {average.toFixed(1)}/day
      </text>
    </svg>
  )
}
