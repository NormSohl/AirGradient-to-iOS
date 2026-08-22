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

    @MainActor
    private var points: [Point] {
        // Registers the observation dependency: `HistoryStore` itself is not
        // observable, so without reading this the chart would never redraw as
        // samples arrive.
        _ = model.historyVersion
        let settings = model.settings
        let raw = model.history.history(for: monitor.id).compactMap { reading -> Point? in
            guard let v = metric.value(from: reading, settings: settings) else { return nil }
            return Point(
                date: reading.timestamp,
                value: v,
                band: metric.band(v, fahrenheit: settings.fahrenheit)
            )
        }
        return segmented(raw)
    }

    /// How far apart samples are *meant* to be for this monitor's source.
    ///
    /// Local monitors are sampled by this app about once a minute. Cloud
    /// history arrives pre-bucketed at five minutes, so judging it by the local
    /// cadence would declare a gap between every pair of points and draw the
    /// series as confetti.
    private var expectedSpacing: TimeInterval {
        if case .cloud = monitor.source { return 300 }
        return 60
    }

    /// Splits the series wherever nothing was recorded for long enough that a
    /// line across the gap would be a claim rather than a measurement.
    ///
    /// Polling only runs in the foreground, so closing the app leaves a real
    /// hole. Drawn as one series, Swift Charts would join the last sample
    /// before the gap to the first one after it and fill underneath — a smooth
    /// trend nobody observed.
    ///
    /// The threshold has to know which tier a sample is in: rolled-up points
    /// are an hour apart on purpose, and would otherwise read as gaps. Judging
    /// by the age of the *earlier* point also keeps the boundary between the
    /// tiers from splitting, where an hourly point is legitimately followed a
    /// full hour later by the first minute-resolution one.
    private func segmented(_ points: [Point]) -> [Point] {
        guard points.count > 1 else { return points }
        let now = Date()
        var out: [Point] = []
        out.reserveCapacity(points.count)
        var segment = 0
        for (i, p) in points.enumerated() {
            if i > 0 {
                let previous = points[i - 1]
                let rolled = now.timeIntervalSince(previous.date) > HistoryStore.fineWindow
                let limit: TimeInterval = rolled ? 3 * 3600 : expectedSpacing * 3
                if p.date.timeIntervalSince(previous.date) > limit { segment += 1 }
            }
            var q = p
            q.segment = segment
            out.append(q)
        }
        return out
    }

    /// Gradient stops that carry the band colouring along the x axis, so the
    /// line and its fill read green/amber/red exactly where the readings did.
    ///
    /// Each run of same-banded samples emits a stop at its start and end, which
    /// holds the colour flat across the run and switches sharply between runs.
    ///
    /// Short runs fold into the run before them, or a reading dithering across
    /// a band boundary produces hundreds of stops and a muddy smear. That
    /// threshold counts **samples**, never a fraction of the visible span:
    /// scaled to the span, a week-wide chart swallowed every excursion shorter
    /// than about two hours — including the tallest spikes on it, which are
    /// also the sharpest — and painted them the colour of the calm either
    /// side. A half-hour spike to 490 drawn green is worse than no colouring.
    private func bandStops(_ series: [Point]) -> [Gradient.Stop] {
        guard let first = series.first, let last = series.last else { return [] }
        let span = last.date.timeIntervalSince(first.date)
        guard span > 0 else {
            return [Gradient.Stop(color: first.band.color, location: 0),
                    Gradient.Stop(color: first.band.color, location: 1)]
        }

        // Keep any run of two or more samples. If a pathological series still
        // yields too many stops, coarsen and retry rather than handing the
        // renderer thousands of them.
        var minRunSamples = 2
        while true {
            var stops: [Gradient.Stop] = []
            var i = 0
            while i < series.count {
                var j = i
                while j + 1 < series.count, series[j + 1].band == series[i].band { j += 1 }

                let startLoc = series[i].date.timeIntervalSince(first.date) / span
                let endLoc = series[j].date.timeIntervalSince(first.date) / span

                if (j - i + 1) < minRunSamples, !stops.isEmpty {
                    stops[stops.count - 1].location = endLoc
                } else {
                    let color = series[i].band.color
                    stops.append(Gradient.Stop(color: color, location: startLoc))
                    stops.append(Gradient.Stop(color: color, location: endLoc))
                }
                i = j + 1
            }
            if stops.count <= 400 || minRunSamples > series.count { return stops }
            minRunSamples *= 2
        }
    }

    /// X-axis interval, never finer than an hour.
    ///
    /// Left automatic, Swift Charts picks whatever divides the span neatly —
    /// which on a few hours of history means half-hour ticks, so the axis fills
    /// with :30 labels that carry no information anyone wants. An hour is the
    /// smallest unit worth labelling here, and stepping up from there keeps the
    /// tick count roughly constant as the history grows.
    private func axisStride(_ series: [Point]) -> (Calendar.Component, Int) {
        guard let first = series.first, let last = series.last else { return (.hour, 1) }
        switch last.date.timeIntervalSince(first.date) / 3600 {
        case ..<7:   return (.hour, 1)
        case ..<15:  return (.hour, 3)
        case ..<30:  return (.hour, 6)
        case ..<80:  return (.hour, 12)
        default:     return (.day, 1)
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

            let series = points
            if series.count < 2 {
                Text("Recording. The monitor doesn't store history itself, so the chart fills in about a point a minute while this app is open.")
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
                .chartXAxis {
                    let step = axisStride(series)
                    AxisMarks(values: .stride(by: step.0, count: step.1))
                }
                .chartYAxis { AxisMarks(position: .leading) }
                // The chart is the main reason to look at this on a tablet;
                // give it the extra height the wider pane affords.
                .frame(height: sizeClass == .regular ? 260 : 160)

                if let last = series.last {
                    HStack(spacing: 6) {
                        Circle().fill(last.band.color).frame(width: 7, height: 7)
                        Text("\(series.count) samples · now \(metric.format(last.value)) \(metric.unit(fahrenheit: model.settings.fahrenheit))")
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
