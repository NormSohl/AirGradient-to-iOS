import Foundation

/// How much history the chart shows.
///
/// The x axis spans the whole range, not just the samples inside it, so each
/// range has one fixed tick layout. Sized from the data instead, the ticks
/// had to be guessed from however much history happened to exist — and when
/// retention grew to a year, a month of it drew thirty day-wide slots with
/// their labels piled on top of each other.
enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month, year

    var id: Self { self }

    var title: String {
        switch self {
        case .day:   "Day"
        case .week:  "Week"
        case .month: "Month"
        case .year:  "Year"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day:   24 * 3600
        case .week:  7 * 24 * 3600
        case .month: 30 * 24 * 3600
        case .year:  365 * 24 * 3600
        }
    }

    /// Tick interval, aligned to calendar boundaries. `compact` is the phone
    /// width, where the day and year layouts halve their label count to fit.
    func axisStride(compact: Bool) -> (component: Calendar.Component, count: Int) {
        switch self {
        case .day:   (.hour, compact ? 6 : 3)
        case .week:  (.day, 1)
        case .month: (.weekOfYear, 1)
        case .year:  (.month, compact ? 3 : 1)
        }
    }

    /// Tick label: the unit the stride steps in, and nothing finer.
    var labelFormat: Date.FormatStyle {
        switch self {
        case .day:   .dateTime.hour()
        case .week:  .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.abbreviated).day()
        case .year:  .dateTime.month(.abbreviated)
        }
    }
}
