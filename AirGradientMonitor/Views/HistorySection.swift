import Charts
import SwiftUI

/// Trend for one metric over whatever history the app has recorded.
///
/// The series is what this app sampled while it was open — the monitor keeps no
/// history of its own — so the empty state says that outright rather than
/// looking like a broken chart, and gaps in the line are real gaps.
struct HistorySection: View {
    @Environment(MonitorsModel.self) private var model
    let monitor: Monitor
    @Binding var metric: Metric

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let band: QualityBand
    }

    @MainActor
    private var points: [Point] {
        // Registers the observation dependency: `HistoryStore` itself is not
        // observable, so without reading this the chart would never redraw as
        // samples arrive.
        _ = model.historyVersion
        let settings = model.settings
        return model.history.history(for: monitor.id).compactMap { reading in
            guard let v = metric.value(from: reading, settings: settings) else { return nil }
            return Point(
                date: reading.timestamp,
                value: v,
                band: metric.band(v, fahrenheit: settings.fahrenheit)
            )
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
                Chart(series) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.tint)

                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 160)

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
