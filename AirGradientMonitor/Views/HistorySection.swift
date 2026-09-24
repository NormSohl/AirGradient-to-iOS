import Charts
import SwiftUI

/// Trend for one metric over whatever history the app has recorded.
///
/// The series is what this app sampled while it was open — the monitor keeps no
/// history of its own — so the empty state says that outright rather than
/// looking like a broken chart, and gaps in the line are real gaps.
struct HistorySection: View {
    @Environment(MonitorsModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let monitor: Monitor
    @Binding var metric: Metric
    /// Remembered across launches: an iPad left on a shelf showing a week
    /// should still show a week after it restarts.
    @AppStorage("historyRange") private var range: HistoryRange = .day

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let band: QualityBand
        /// Which unbroken stretch of recording this belongs to. Drawn as the
        /// mark's `series`, so the line and fill break at gaps instead of
        /// bridging them.
        var segment: Int = 0
    }

    private var isCloud: Bool {
        if case .cloud = monitor.source { return true }
        return false
    }

    /// Points for the current metric recorded since `start`, plus whether any
    /// exist at all — so an empty window can say the history is merely older,
    /// not missing.
    @MainActor
    private func points(since start: Date) -> (series: [Point], anyRecorded: Bool) {
        // Registers the observation dependency: `HistoryStore` itself is not
        // observable, so without reading this the chart would never redraw as
        // samples arrive.
        _ = model.historyVersion
        let settings = model.settings
        var anyRecorded = false
        let raw = model.history.history(for: monitor.id).compactMap { reading -> Point? in
            guard let v = metric.value(from: reading, settings: settings) else { return nil }
            anyRecorded = true
            guard reading.timestamp >= start else { return nil }
            return Point(
                date: reading.timestamp,
                value: v,
                band: metric.band(v, fahrenheit: settings.fahrenheit)
            )
        }
        return (segmented(raw), anyRecorded)
    }

    /// Local monitors are polled about once a minute; cloud history arrives in
    /// five-minute buckets.
    private var expectedSpacing: TimeInterval {
        if case .cloud = monitor.source { return SeriesShaping.cloudSpacing }
        return SeriesShaping.localSpacing
    }

    /// Tags each point with the unbroken stretch it belongs to, so the line and
    /// fill break where nothing was recorded instead of bridging the hole.
    private func segmented(_ points: [Point]) -> [Point] {
        let segments = SeriesShaping.segments(
            points.map { SeriesShaping.Sample(date: $0.date, band: $0.band) },
            expectedSpacing: expectedSpacing,
            fineWindow: HistoryStore.fineWindow,
            now: Date()
        )
        return zip(points, segments).map { point, segment in
            var p = point
            p.segment = segment
            return p
        }
    }

    /// Gradient stops carrying the band colouring along the x axis, so the line
    /// and its fill read green/amber/red exactly where the readings did.
    private func bandStops(_ series: [Point]) -> [Gradient.Stop] {
        let runs = SeriesShaping.bandRuns(series.map { SeriesShaping.Sample(date: $0.date, band: $0.band) })
        return runs.flatMap { run in
            [Gradient.Stop(color: run.band.color, location: run.start),
             Gradient.Stop(color: run.band.color, location: run.end)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(Metric.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let now = Date()
            let start = now.addingTimeInterval(-range.duration)
            let (series, anyRecorded) = points(since: start)
            if series.count < 2 {
                Text(anyRecorded
                     ? "Nothing recorded in the last \(range.title.lowercased()). Pick a longer range to see older history."
                     : isCloud
                     ? "Fetching history from AirGradient."
                     : "Recording. The monitor doesn't store history itself, so the chart fills in about a point a minute while this app is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                let bandGradient = LinearGradient(
                    stops: bandStops(series),
                    startPoint: .leading,
                    endPoint: .trailing
                )

                Chart(series) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(metric.title, point.value),
                        series: .value("Recording", point.segment)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(bandGradient)

                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value(metric.title, point.value),
                        series: .value("Recording", point.segment)
                    )
                    .interpolationMethod(.monotone)
                    // Same colouring, well below the line: the fill is there to
                    // give the line a body, not to compete with it.
                    .foregroundStyle(bandGradient.opacity(0.22))
                }
                // The whole range, not just the data: each range keeps one tick
                // layout, and history that doesn't reach back that far shows
                // as empty space rather than being stretched to fill it.
                .chartXScale(domain: start...now)
                .chartXAxis {
                    let step = range.axisStride(compact: sizeClass != .regular)
                    AxisMarks(values: .stride(by: step.component, count: step.count)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: range.labelFormat)
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                // The chart is the main reason to look at this on a tablet;
                // give it the extra height the wider pane affords.
                .frame(height: sizeClass == .regular ? 260 : 160)

                if let last = series.last {
                    let average = SeriesShaping.timeWeightedMean(series.map { ($0.date, $0.value) })
                    HStack(spacing: 6) {
                        Circle().fill(last.band.color).frame(width: 7, height: 7)
                        Text("\(series.count) samples · avg \(average.map(metric.format) ?? "—") · now \(metric.format(last.value)) \(metric.unit(fahrenheit: model.settings.fahrenheit))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground(cornerRadius: 14)
    }
}
