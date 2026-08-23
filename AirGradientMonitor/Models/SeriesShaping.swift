import Foundation

/// The two decisions that turn a list of samples into a drawable series:
/// where the recording broke, and where the air quality changed.
///
/// Both live here rather than inside `HistorySection` because both have been
/// wrong in ways no amount of reading caught — a gap rule written for local
/// cadence shattered cloud data into confetti, and a run-folding rule scaled to
/// the visible span erased exactly the sharp spikes worth seeing. Logic with
/// that history should be testable without a view around it.
enum SeriesShaping {
    /// The minimum a caller has to know about a sample to shape it.
    struct Sample {
        let date: Date
        let band: QualityBand

        init(date: Date, band: QualityBand) {
            self.date = date
            self.band = band
        }
    }

    /// How far apart samples are *meant* to be, by source. Local monitors are
    /// polled about once a minute; cloud history arrives in five-minute buckets.
    static let localSpacing: TimeInterval = 60
    static let cloudSpacing: TimeInterval = 300

    /// Index of the unbroken stretch each sample belongs to.
    ///
    /// Polling only runs in the foreground, so closing the app leaves a real
    /// hole. Drawn as one series, a chart joins the last sample before the gap
    /// to the first after it and fills underneath — a smooth trend nobody
    /// observed.
    ///
    /// The threshold knows which retention tier a sample is in: rolled-up
    /// points are an hour apart on purpose and must not read as gaps. Judging
    /// by the age of the *earlier* point also keeps the tier boundary itself
    /// from splitting, where an hourly point is legitimately followed a full
    /// hour later by the first minute-resolution one.
    static func segments(
        _ samples: [Sample],
        expectedSpacing: TimeInterval,
        fineWindow: TimeInterval,
        now: Date
    ) -> [Int] {
        guard samples.count > 1 else { return Array(repeating: 0, count: samples.count) }
        var out: [Int] = [0]
        out.reserveCapacity(samples.count)
        var segment = 0
        for i in 1..<samples.count {
            let previous = samples[i - 1]
            let rolled = now.timeIntervalSince(previous.date) > fineWindow
            let limit: TimeInterval = rolled ? 3 * 3600 : expectedSpacing * 3
            if samples[i].date.timeIntervalSince(previous.date) > limit { segment += 1 }
            out.append(segment)
        }
        return out
    }

    /// A stretch of same-banded samples, positioned 0...1 along the series.
    struct Run: Equatable {
        var band: QualityBand
        var start: Double
        var end: Double
    }

    /// Runs of like-banded samples, for colouring a line along its length.
    ///
    /// Short runs fold into the run before them, or a reading dithering across
    /// a band boundary produces hundreds of them and a muddy smear. That
    /// threshold counts **samples**, never a fraction of the visible span:
    /// scaled to the span, a week-wide chart swallowed every excursion shorter
    /// than about two hours — which is precisely the sharp, tall spikes — and
    /// painted them the colour of the calm either side. A half-hour spike to
    /// 490 drawn green is worse than no colouring at all.
    static func bandRuns(_ samples: [Sample], maxRuns: Int = 200) -> [Run] {
        guard let first = samples.first, let last = samples.last else { return [] }
        let span = last.date.timeIntervalSince(first.date)
        guard span > 0 else { return [Run(band: first.band, start: 0, end: 1)] }

        var minRunSamples = 2
        while true {
            var runs: [Run] = []
            var i = 0
            while i < samples.count {
                var j = i
                while j + 1 < samples.count, samples[j + 1].band == samples[i].band { j += 1 }

                let start = samples[i].date.timeIntervalSince(first.date) / span
                let end = samples[j].date.timeIntervalSince(first.date) / span

                if (j - i + 1) < minRunSamples, !runs.isEmpty {
                    runs[runs.count - 1].end = end      // absorb the blip
                } else {
                    runs.append(Run(band: samples[i].band, start: start, end: end))
                }
                i = j + 1
            }
            if runs.count <= maxRuns || minRunSamples > samples.count { return runs }
            minRunSamples *= 2
        }
    }
}
